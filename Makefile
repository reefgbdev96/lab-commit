MODULES := apps/backend apps/frontend apps/loadgen
TF_ROOTS := terraform/bootstrap terraform/envs/lab
CHART := charts/lab-commit

.PHONY: build test lint vuln tidy tidy-check fmt fmt-check validate chart-lint check e2e \
	init delete-default-vpc tunnel-eks kubeconfig tunnel-db db-bootstrap db-shell gitops-env bootstrap teardown-k8s

## Development — no AWS access needed. No target takes a token.

build:
	@for m in $(MODULES); do echo "==> build $$m"; (cd $$m && go build -o /dev/null ./...) || exit 1; done

test:
	@for m in $(MODULES); do echo "==> test $$m"; (cd $$m && go test -race -count=1 ./...) || exit 1; done

lint:
	@for m in $(MODULES); do echo "==> lint $$m"; (cd $$m && go vet ./... && golangci-lint run) || exit 1; done

vuln:
	@for m in $(MODULES); do echo "==> vuln $$m"; (cd $$m && govulncheck ./...) || exit 1; done

tidy:
	@for m in $(MODULES); do (cd $$m && go mod tidy) || exit 1; done

tidy-check:
	@for m in $(MODULES); do (cd $$m && go mod tidy -diff) || exit 1; done

fmt:
	@for m in $(MODULES); do (cd $$m && gofmt -w .); done
	@terraform fmt -recursive terraform

fmt-check:
	@test -z "$$(gofmt -l $(MODULES))" || { gofmt -l $(MODULES); exit 1; }
	@terraform fmt -check -recursive terraform

validate:
	@for r in $(TF_ROOTS); do echo "==> validate $$r"; \
		terraform -chdir=$$r init -backend=false -input=false -lockfile=readonly >/dev/null && \
		terraform -chdir=$$r validate || exit 1; done

chart-lint:
	@helm lint $(CHART) -f test/e2e/values.yaml
	@helm template lab-commit $(CHART) -f test/e2e/values.yaml >/dev/null
	@# ConfigMap files must survive YAML intact: the dashboard as JSON, the CA with its newlines.
	@helm template lab-commit $(CHART) -f test/e2e/values.yaml --set-string "loadgen.caCert=$$(printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----')" > /tmp/lab-commit-render.yaml
	@yq 'select(.metadata.name == "lab-commit-dashboard") | .data["lab-commit.json"] | tag' /tmp/lab-commit-render.yaml | grep -qx '!!str' || { echo "dashboard ConfigMap data is not a string"; exit 1; }
	@yq 'select(.metadata.name == "lab-commit-dashboard") | .data["lab-commit.json"]' /tmp/lab-commit-render.yaml | jq -e .panels >/dev/null || { echo "dashboard ConfigMap is not valid JSON"; exit 1; }
	@yq 'select(.metadata.name == "lab-ca") | .data["ca.crt"]' /tmp/lab-commit-render.yaml | grep -qx -- '-----BEGIN CERTIFICATE-----' || { echo "CA ConfigMap lost its line breaks"; exit 1; }
	@helm lint gitops/apps -f test/gitops-apps-values.yaml
	@helm template root gitops/apps -f test/gitops-apps-values.yaml >/dev/null

check: tidy-check build test lint vuln fmt-check validate chart-lint

# Local end-to-end proof on kind (needs Docker): restricted PSS, Prometheus,
# KEDA 1 -> 4 -> 1, DB round trip.
e2e:
	@test/e2e/run.sh

## Operations - need AWS credentials; run in README "Runbook" order.
## tunnel-eks and tunnel-db stay in the foreground: give each its own terminal.

init delete-default-vpc tunnel-eks kubeconfig tunnel-db db-bootstrap db-shell gitops-env bootstrap teardown-k8s:
	@scripts/ops.sh $@
