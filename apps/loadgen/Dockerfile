# Cross-compiles on the build host: CodeBuild produces linux/amd64. ECR Public,
# not Docker Hub: CodeBuild shares IPs and hits Docker Hub's anonymous pull limit.
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/golang:1.26.10-alpine AS build
ARG TARGETOS TARGETARCH VERSION=dev
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/app .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/app /app
# Numeric, so the kubelet can verify runAsNonRoot.
USER 65532:65532
ENTRYPOINT ["/app"]
