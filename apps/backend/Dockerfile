# Cross-compiles on the build host: CodeBuild produces linux/amd64. ECR Public,
# not Docker Hub: CodeBuild shares IPs and hits Docker Hub's anonymous pull limit.
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/golang:1.26.10-alpine AS build
ARG TARGETOS TARGETARCH VERSION=dev
# RDS CA bundle for sslmode=verify-full. If AWS publishes a new bundle the
# checksum fails the build on purpose: re-pin it.
ARG RDS_CA_SHA256=90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b
RUN wget -qO /rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
 && echo "${RDS_CA_SHA256}  /rds-ca.pem" | sha256sum -c -
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/app .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /rds-ca.pem /etc/ssl/certs/rds-ca.pem
COPY --from=build /out/app /app
# Numeric, so the kubelet can verify runAsNonRoot.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
