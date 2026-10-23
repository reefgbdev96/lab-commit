package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// newPool connects to PostgreSQL. With iamAuth every new connection authenticates
// with a short-lived RDS IAM token (credentials from IRSA), so the app holds no
// database password at all.
func newPool(ctx context.Context, dsn string, iamAuth bool) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		// The error embeds the DSN, and pgx only redacts passwords best-effort:
		// a Secrets Manager JSON blob is echoed verbatim. Never wrap it.
		return nil, errors.New("DATABASE_URL is not a valid PostgreSQL connection string")
	}
	if iamAuth {
		// The token is a 15-minute credential: only send it to a verified server.
		if tlsCfg := cfg.ConnConfig.TLSConfig; tlsCfg == nil || tlsCfg.InsecureSkipVerify {
			return nil, errors.New("DB_IAM_AUTH requires sslmode=verify-full in DATABASE_URL")
		}
		awsCfg, err := config.LoadDefaultConfig(ctx)
		if err != nil {
			return nil, fmt.Errorf("load AWS config: %w", err)
		}
		if awsCfg.Region == "" {
			return nil, errors.New("DB_IAM_AUTH requires AWS_REGION")
		}
		cfg.BeforeConnect = iamPassword(awsCfg.Region, awsCfg.Credentials)
	}
	return pgxpool.NewWithConfig(ctx, cfg)
}

// iamPassword returns a BeforeConnect hook that sets a fresh IAM auth token as the
// password. Tokens last 15 minutes but are only checked at login.
func iamPassword(region string, creds aws.CredentialsProvider) func(context.Context, *pgx.ConnConfig) error {
	return func(ctx context.Context, cc *pgx.ConnConfig) error {
		endpoint := net.JoinHostPort(cc.Host, strconv.Itoa(int(cc.Port)))
		token, err := auth.BuildAuthToken(ctx, endpoint, region, cc.User, creds)
		if err != nil {
			return fmt.Errorf("build RDS IAM auth token: %w", err)
		}
		cc.Password = token
		return nil
	}
}
