#!/usr/bin/env bash
# Proves the riskiest behaviour without AWS, on a throwaway kind cluster:
#   - the chart runs under the restricted Pod Security Standard (numeric non-root user)
#   - Prometheus scrapes the apps, and reads cAdvisor through the API-server proxy
#     exactly as on Fargate
#   - db/bootstrap.sql is idempotent and leaves lab_app read-only
#   - a DB update reaches the page within one poll
#   - KEDA scales the frontend 1 -> 4 on request rate, and back to 1 when load stops
# Needs Docker, kind, helm, kubectl. KEEP=1 keeps the cluster for debugging.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLUSTER=lab-commit-e2e
CONTEXT=kind-$CLUSTER
VERSION=v0.0.0-e2e

k() { kubectl --context "$CONTEXT" "$@"; }
h() { helm --kube-context "$CONTEXT" "$@"; }
psql_e2e() { k -n e2e-db exec -i deploy/postgres -- psql -U postgres -d labdb -v ON_ERROR_STOP=1 "$@"; }

pids=()
cleanup() {
  ((${#pids[@]})) && kill "${pids[@]}" 2>/dev/null || true
  [[ ${KEEP:-0} == 1 ]] || kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# wait_for <description> <timeout seconds> <command...>
wait_for() {
  local what=$1 timeout=$2 start=$SECONDS
  shift 2
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS - start > timeout)); then
      echo "FAIL: $what (after ${timeout}s)"
      exit 1
    fi
    sleep 5
  done
  echo "PASS: $what ($((SECONDS - start))s)"
}

page_is() { [[ $(curl -sf http://127.0.0.1:18080/) == "$1" ]]; }
ready_replicas_is() { [[ $(k -n demo get deploy frontend -o jsonpath='{.status.readyReplicas}') == "$1" ]]; }
prometheus_has() { curl -sf --get http://127.0.0.1:19090/api/v1/query --data-urlencode "query=$1" | grep -q '"result":\[{'; }

kind create cluster --name "$CLUSTER" --wait 120s

for svc in frontend backend loadgen; do
  docker build -q --build-arg VERSION=$VERSION -t "lab-commit/$svc:e2e" "apps/$svc"
  kind load docker-image --name "$CLUSTER" "lab-commit/$svc:e2e"
done

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo update prometheus-community kedacore >/dev/null
h upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 92.11.0 \
  --namespace monitoring --create-namespace \
  -f gitops/values/monitoring.yaml -f test/e2e/monitoring.yaml --wait --timeout 10m
h upgrade --install keda kedacore/keda --version 2.21.0 --namespace keda --create-namespace --wait --timeout 5m

k apply -f test/e2e/postgres.yaml
k -n e2e-db rollout status deploy/postgres --timeout 180s
for run in 1 2; do # twice: proves the script is idempotent
  psql_e2e --single-transaction <db/bootstrap.sql >/dev/null
  echo "PASS: db/bootstrap.sql run $run"
done
# The UPDATE must fail; capture first, since psql's non-zero exit would fail a pipeline.
write_attempt=$(psql_e2e -c "SET ROLE lab_app; UPDATE messages SET value = 'x' WHERE id = 1" 2>&1 || true)
if [[ $write_attempt == *"permission denied"* ]]; then
  echo "PASS: lab_app is read-only"
else
  echo "FAIL: lab_app could write"
  exit 1
fi

k create namespace demo
k label namespace demo pod-security.kubernetes.io/enforce=restricted
h install lab-commit charts/lab-commit --namespace demo -f test/e2e/values.yaml --wait --timeout 5m

k -n demo port-forward svc/frontend 18080:80 >/dev/null 2>&1 &
pids+=($!)
k -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 &
pids+=($!)

wait_for "page shows the build version and DB value" 60 page_is "Hello Lab-Commit $VERSION (db: 5)"
psql_e2e -c "UPDATE messages SET value = '6' WHERE id = 1" >/dev/null
wait_for "DB update visible within one poll" 20 page_is "Hello Lab-Commit $VERSION (db: 6)"
wait_for "Prometheus scrapes the frontend" 120 prometheus_has 'http_requests_total{namespace="demo",service="frontend"}'
wait_for "cAdvisor via the API-server proxy (the Fargate path)" 120 prometheus_has 'container_memory_working_set_bytes{namespace="demo"}'
wait_for "frontend scales to 4 under load" 420 ready_replicas_is 4

k -n demo scale deploy/loadgen --replicas=0
wait_for "frontend scales back to 1 once load stops" 360 ready_replicas_is 1

echo "e2e passed"
