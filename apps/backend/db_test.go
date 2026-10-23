package main

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/jackc/pgx/v5"
)

// A Secrets Manager JSON blob passed as DATABASE_URL makes pgx echo the input
// verbatim; the error must never carry the password into logs.
func TestNewPoolNeverLeaksDSN(t *testing.T) {
	_, err := newPool(context.Background(), `{"username":"admin","password":"Pa55w0rd"}`, false)
	if err == nil || strings.Contains(err.Error(), "Pa55w0rd") {
		t.Fatalf("want a redacted error, got %v", err)
	}
}

func TestIAMPasswordSetsSignedToken(t *testing.T) {
	cc, err := pgx.ParseConfig("postgres://lab_app@db.example.com:5432/labdb")
	if err != nil {
		t.Fatal(err)
	}
	hook := iamPassword("us-east-1", credentials.NewStaticCredentialsProvider("AKIDEXAMPLE", "secret", ""))
	if err := hook(context.Background(), cc); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"db.example.com:5432", "Action=connect", "DBUser=lab_app", "X-Amz-Signature="} {
		if !strings.Contains(cc.Password, want) {
			t.Errorf("token %q missing %q", cc.Password, want)
		}
	}
}

// An IAM token is a 15-minute credential: never send it over a connection that
// does not verify the server certificate.
func TestNewPoolRequiresVerifiedTLSForIAMAuth(t *testing.T) {
	for _, mode := range []string{"disable", "prefer", "require"} {
		_, err := newPool(context.Background(), "postgres://lab_app@db.example.com:5432/labdb?sslmode="+mode, true)
		if err == nil || !strings.Contains(err.Error(), "verify-full") {
			t.Errorf("sslmode=%s: want a verify-full error, got %v", mode, err)
		}
	}
}

func TestNewPoolIAMAuthNeedsRegion(t *testing.T) {
	t.Setenv("AWS_REGION", "")
	t.Setenv("AWS_DEFAULT_REGION", "")
	t.Setenv("AWS_CONFIG_FILE", t.TempDir()+"/none") // ignore any local ~/.aws/config

	_, err := newPool(context.Background(), "postgres://lab_app@db.example.com:5432/labdb?sslmode=verify-full", true)
	if err == nil || !strings.Contains(err.Error(), "AWS_REGION") {
		t.Fatalf("verify-full without a region: want an AWS_REGION error, got %v", err)
	}
}
