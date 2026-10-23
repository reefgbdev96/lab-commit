// Command backend serves a value read from PostgreSQL.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

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

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("DATABASE_URL is required")
	}

	pool, err := newPool(ctx, dsn, os.Getenv("DB_IAM_AUTH") == "true")
	if err != nil {
		return err
	}
	defer pool.Close()

	// pgxpool only parses the DSN; Ping is what proves the database is reachable.
	pingCtx, cancelPing := context.WithTimeout(ctx, 10*time.Second)
	defer cancelPing()
	if err := pool.Ping(pingCtx); err != nil {
		if ctx.Err() != nil {
			return nil // SIGTERM during startup is a normal shutdown, not a failure
		}
		return fmt.Errorf("ping database: %w", err)
	}

	srv := &http.Server{
		Handler:           newServer(pool).routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 16,
	}

	ln, err := net.Listen("tcp", ":8080")
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	slog.Info("listening", "addr", ln.Addr().String(), "version", version)

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
	return srv.Shutdown(shutdown)
}
