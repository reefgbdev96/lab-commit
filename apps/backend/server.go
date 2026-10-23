package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// querier is the subset of pgxpool.Pool the handlers use, so tests can supply a fake.
type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Ping(ctx context.Context) error
}

type server struct {
	db       querier
	registry *prometheus.Registry
	requests *prometheus.CounterVec
}

// newServer builds a server with its own registry, so /metrics exposes only this
// service's metrics and each test gets an isolated one.
func newServer(db querier) *server {
	registry := prometheus.NewRegistry()
	return &server{
		db:       db,
		registry: registry,
		requests: promauto.With(registry).NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests by path and status code.",
		}, []string{"path", "status"}),
	}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /api/value", s.count("/api/value", s.handleValue))
	mux.Handle("GET /healthz", http.HandlerFunc(s.handleHealth))
	mux.Handle("GET /readyz", http.HandlerFunc(s.handleReady))
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.registry, promhttp.HandlerOpts{}))
	return mux
}

// count records each response against http_requests_total (request-rate panel).
func (s *server) count(path string, next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next(rec, r)
		s.requests.WithLabelValues(path, strconv.Itoa(rec.status)).Inc()
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController reach the underlying writer's optional
// interfaces (Flusher, Hijacker) through this wrapper.
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func (s *server) handleValue(w http.ResponseWriter, r *http.Request) {
	var value string
	err := s.db.QueryRow(r.Context(), "SELECT value FROM messages WHERE id = 1").Scan(&value)
	if err != nil {
		slog.Error("query value", "err", err)
		http.Error(w, "database unavailable", http.StatusServiceUnavailable)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]string{"value": value}); err != nil {
		slog.Error("encode response", "err", err)
	}
}

// handleHealth is liveness: it must not depend on the database, or a brief
// outage would have the kubelet restart otherwise-healthy pods.
func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// handleReady is readiness: no database, no traffic.
func (s *server) handleReady(w http.ResponseWriter, r *http.Request) {
	if err := s.db.Ping(r.Context()); err != nil {
		slog.Warn("readiness ping failed", "err", err)
		http.Error(w, "database unavailable", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}
