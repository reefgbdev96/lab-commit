package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

type fakeRow struct {
	value string
	err   error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	*dest[0].(*string) = r.value
	return nil
}

type fakeDB struct {
	row     pgx.Row
	pingErr error
}

func (d fakeDB) QueryRow(context.Context, string, ...any) pgx.Row { return d.row }
func (d fakeDB) Ping(context.Context) error                       { return d.pingErr }

func TestHandleReady(t *testing.T) {
	tests := []struct {
		name     string
		pingErr  error
		wantCode int
	}{
		{name: "ready when the database answers", pingErr: nil, wantCode: http.StatusOK},
		{name: "not ready when the database is down", pingErr: errors.New("no route to host"), wantCode: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			newServer(fakeDB{pingErr: tt.pingErr}).routes().ServeHTTP(
				rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))

			if rec.Code != tt.wantCode {
				t.Errorf("status = %d, want %d", rec.Code, tt.wantCode)
			}
		})
	}
}

// Liveness must stay independent of the database, or a blip gets healthy pods restarted.
func TestHandleHealthIgnoresDatabase(t *testing.T) {
	rec := httptest.NewRecorder()
	newServer(fakeDB{pingErr: errors.New("down")}).routes().ServeHTTP(
		rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

// TestMetricsExposesRequestCounter pins the request counter the dashboard reads: renaming
// http_requests_total would silently empty its panels.
func TestMetricsExposesRequestCounter(t *testing.T) {
	srv := newServer(fakeDB{row: fakeRow{value: "5"}}).routes()
	srv.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/value", nil))

	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if !strings.Contains(rec.Body.String(), `http_requests_total{path="/api/value",status="200"} 1`) {
		t.Errorf("http_requests_total not exposed as expected, got:\n%s", rec.Body.String())
	}
}

func TestHandleValue(t *testing.T) {
	tests := []struct {
		name     string
		row      pgx.Row
		wantCode int
		wantBody string
	}{
		{
			name:     "returns the value from the database",
			row:      fakeRow{value: "5"},
			wantCode: http.StatusOK,
			wantBody: `{"value":"5"}` + "\n",
		},
		{
			name:     "reports unavailable when query fails",
			row:      fakeRow{err: errors.New("connection refused")},
			wantCode: http.StatusServiceUnavailable,
			wantBody: "database unavailable\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			newServer(fakeDB{row: tt.row}).routes().ServeHTTP(
				rec, httptest.NewRequest(http.MethodGet, "/api/value", nil))

			if rec.Code != tt.wantCode {
				t.Errorf("status = %d, want %d", rec.Code, tt.wantCode)
			}
			if rec.Body.String() != tt.wantBody {
				t.Errorf("body = %q, want %q", rec.Body.String(), tt.wantBody)
			}
		})
	}
}
