package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type server struct {
	version  string
	values   interface{ current() (string, error) }
	registry *prometheus.Registry
	requests *prometheus.CounterVec
}

// newServer builds a server with its own registry, so /metrics exposes only this
// service's metrics and each test gets an isolated one.
func newServer(version string, values interface{ current() (string, error) }) *server {
	registry := prometheus.NewRegistry()
	return &server{
		version:  version,
		values:   values,
		registry: registry,
		requests: promauto.With(registry).NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests by path and status code.",
		}, []string{"path", "status"}),
	}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /{$}", s.count("/", s.handleRoot))
	mux.Handle("GET /healthz", http.HandlerFunc(s.handleHealth))
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.registry, promhttp.HandlerOpts{}))
	return mux
}

// count records each response against http_requests_total, the metric KEDA scales on.
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

// handleRoot always answers: the version is compiled in and the DB value degrades
// to "n/a", so a backend outage never fails the page or frontend readiness.
func (s *server) handleRoot(w http.ResponseWriter, _ *http.Request) {
	value, err := s.values.current()
	if err != nil {
		value = "n/a"
	}
	// The browser re-fetches every poll interval, making the 5s refresh visible.
	w.Header().Set("Refresh", strconv.Itoa(int(pollInterval/time.Second)))
	if _, err := fmt.Fprintf(w, "Hello Lab-Commit %s (db: %s)\n", s.version, value); err != nil {
		slog.Warn("write response", "err", err)
	}
}

// handleHealth serves liveness and readiness: the page never depends on the
// backend, so readiness has nothing more to check.
func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}
