// Command frontend serves the greeting: its own build version plus a value it
// polls from the backend.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

const pollInterval = 5 * time.Second

var version = "dev" // set at build time: -ldflags "-X main.version=..."

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

// run owns the process lifecycle so every deferred cleanup runs; main only
// translates a failure into an exit code.
func run() error {
	// Trap signals before the listener starts, so a SIGTERM arriving during
	// startup shuts down gracefully instead of killing the process outright.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	endpoint, err := valueEndpoint(os.Getenv("BACKEND_URL"))
	if err != nil {
		return err
	}

	// The poller outlives the shutdown signal: it must keep serving the cached
	// value while the server drains.
	pollCtx, stopPoll := context.WithCancel(context.Background())
	defer stopPoll()

	values := newPoller(endpoint, pollInterval)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		values.run(pollCtx)
	}()

	srv := &http.Server{
		Handler:           newServer(version, values).routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		// Must exceed the ALB idle timeout (60s), or the ALB can reuse a keep-alive
		// connection the server is closing and answer the client with a 502.
		IdleTimeout:    75 * time.Second,
		MaxHeaderBytes: 1 << 16,
	}

	ln, err := net.Listen("tcp", ":8080")
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	slog.Info("listening", "addr", ln.Addr().String(), "version", version, "backend", endpoint)

	serveErr := make(chan error, 1)
	go func() {
		if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
		}
	}()

	select {
	case err := <-serveErr:
		return fmt.Errorf("serve: %w", err)
	case <-ctx.Done():
	}

	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	shutdownErr := srv.Shutdown(shutdown)

	stopPoll()
	wg.Wait()
	return shutdownErr
}

// valueEndpoint validates BACKEND_URL once at startup and builds the poll URL
// with JoinPath, so a stray "?" or "#" cannot swallow the path.
func valueEndpoint(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return "", fmt.Errorf("BACKEND_URL must be an absolute http(s) URL, got %q", raw)
	}
	return u.JoinPath("api", "value").String(), nil
}
