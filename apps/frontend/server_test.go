package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type fakeValues struct {
	value string
	err   error
}

func (f fakeValues) current() (string, error) { return f.value, f.err }

func TestHandleRoot(t *testing.T) {
	tests := []struct {
		name     string
		values   fakeValues
		wantBody string
	}{
		{
			name:     "shows the build version and the polled DB value",
			values:   fakeValues{value: "5"},
			wantBody: "Hello Lab-Commit v9.9.9 (db: 5)\n",
		},
		{
			name:     "still answers before the first successful poll",
			values:   fakeValues{err: errors.New("no successful poll yet")},
			wantBody: "Hello Lab-Commit v9.9.9 (db: n/a)\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			newServer("v9.9.9", tt.values).routes().ServeHTTP(
				rec, httptest.NewRequest(http.MethodGet, "/", nil))

			if rec.Code != http.StatusOK {
				t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
			}
			if rec.Body.String() != tt.wantBody {
				t.Errorf("body = %q, want %q", rec.Body.String(), tt.wantBody)
			}
			if got := rec.Header().Get("Refresh"); got != "5" {
				t.Errorf("Refresh header = %q, want %q", got, "5")
			}
		})
	}
}

// Liveness must stay independent of the backend, or an outage gets every
// frontend pod restarted instead of serving cached values.
func TestHandleHealthIgnoresBackend(t *testing.T) {
	rec := httptest.NewRecorder()
	newServer("v9.9.9", fakeValues{err: errors.New("backend down")}).routes().ServeHTTP(
		rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestValueEndpoint(t *testing.T) {
	tests := []struct {
		raw     string
		want    string
		wantErr bool
	}{
		{raw: "http://backend", want: "http://backend/api/value"},
		{raw: "http://backend:8080/", want: "http://backend:8080/api/value"},
		{raw: "https://backend", want: "https://backend/api/value"},
		{raw: "http://backend:8080?x=1", want: "http://backend:8080/api/value?x=1"}, // query must not swallow the path
		{raw: "", wantErr: true},
		{raw: "backend:8080", wantErr: true},  // no scheme
		{raw: "ftp://backend", wantErr: true}, // wrong scheme
		{raw: "http://", wantErr: true},       // no host
	}

	for _, tt := range tests {
		t.Run(tt.raw, func(t *testing.T) {
			got, err := valueEndpoint(tt.raw)
			if (err != nil) != tt.wantErr {
				t.Fatalf("valueEndpoint(%q) error = %v, wantErr %v", tt.raw, err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("valueEndpoint(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

// An empty value must be treated as a failed poll, not cached and shown as "(db: )".
func TestPollerRejectsEmptyValue(t *testing.T) {
	for _, body := range []string{`{"value":""}`, `{}`} {
		backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte(body)) //nolint:errcheck // test handler
		}))

		p := newPoller(backend.URL+"/api/value", time.Hour)
		p.poll(context.Background())
		if _, err := p.current(); err == nil {
			t.Errorf("body %s: current() returned no error, want one", body)
		}
		backend.Close()
	}
}

// TestMetricsExposesRequestCounter guards the metric KEDA scales on: renaming
// http_requests_total silently breaks autoscaling, so pin it here.
func TestMetricsExposesRequestCounter(t *testing.T) {
	srv := newServer("v9.9.9", fakeValues{value: "5"}).routes()
	srv.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))

	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if !strings.Contains(rec.Body.String(), `http_requests_total{path="/",status="200"} 1`) {
		t.Errorf("http_requests_total not exposed as expected, got:\n%s", rec.Body.String())
	}
}

func TestPollerServesLastGoodValueWhenBackendFails(t *testing.T) {
	var fail atomic.Bool
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if fail.Load() {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		w.Write([]byte(`{"value":"5"}`)) //nolint:errcheck // test handler
	}))
	defer backend.Close()

	p := newPoller(backend.URL+"/api/value", time.Hour)
	p.poll(context.Background())

	if got, err := p.current(); err != nil || got != "5" {
		t.Fatalf("current() = %q, %v; want 5, nil", got, err)
	}

	fail.Store(true)
	p.poll(context.Background())

	// A failing backend must not blank the cached value.
	if got, err := p.current(); err != nil || got != "5" {
		t.Errorf("after failure current() = %q, %v; want 5, nil", got, err)
	}
}
