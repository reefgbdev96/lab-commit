#!/usr/bin/env bash
# Operator commands for the AWS lab, in README "Runbook" order. Run through make
# (make tunnel-eks, make bootstrap, ...). Every kubectl/helm call names its
# context explicitly, so nothing can land on another cluster in your kubeconfig.
set -euo pipefail
cd "$(dirname "$0")/.."

TF=terraform/envs/lab
CONTEXT=lab-commit
EXPECTED_APPS=(root aws-load-balancer-controller kube-prometheus-stack keda external-dns lab-commit)

out() { terraform -chdir="$TF" output -raw "$1"; }
k() { kubectl --context "$CONTEXT" "$@"; }
confirm() { read -r -p "$1 [y/N] " reply && [[ $reply == y ]]; }
api_host() { out cluster_endpoint | sed 's#^https://##'; }

rds_ca() {
  local file="${TMPDIR:-/tmp}/rds-ca.pem"
  [[ -s $file ]] || curl -sfo "$file" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
  echo "$file"
}

cmd_init() {
  terraform -chdir="$TF" init \
    -backend-config="bucket=$(terraform -chdir=terraform/bootstrap output -raw bucket)" \
    -backend-config="region=$(terraform -chdir=terraform/bootstrap output -raw region)"
}

# The spec asks for the default VPC to be deleted. Irreversible for the region
# (recreate with `aws ec2 create-default-vpc`), so it asks first.
cmd_delete_default_vpc() {
  local region="${AWS_REGION:-$(aws configure get region)}" vpc
  vpc=$(aws ec2 describe-vpcs --region "$region" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ $vpc != None ]] || { echo "No default VPC in $region."; return 0; }
  confirm "Delete the default VPC $vpc in $region?" || return 1

  for igw in $(aws ec2 describe-internet-gateways --region "$region" --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$igw" --vpc-id "$vpc"
    aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$igw"
  done
  for subnet in $(aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --region "$region" --subnet-id "$subnet"
  done
  aws ec2 delete-vpc --region "$region" --vpc-id "$vpc"
}

# Port-forward through the jump box: forward <remote host> <remote port> <local port>.
forward() {
  aws ssm start-session --region "$(out region)" --target "$(out jumpbox_instance_id)" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=$1,portNumber=$2,localPortNumber=$3"
}
cmd_tunnel_eks() { forward "$(api_host)" 443 8443; }
cmd_tunnel_db() { forward "$(out rds_address)" 5432 15432; }

cmd_kubeconfig() {
  aws eks update-kubeconfig --region "$(out region)" --name "$(out cluster_name)" --alias "$CONTEXT"
  local cluster
  cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CONTEXT\")].context.cluster}")
  # Reach the private API through the tunnel while still verifying its certificate.
  kubectl config set-cluster "$cluster" --server=https://127.0.0.1:8443 --tls-server-name="$(api_host)"
}

# psql through the DB tunnel as the RDS master user. The password goes through the
# environment, never argv or a file.
psql_master() {
  local secret
  secret=$(aws secretsmanager get-secret-value --region "$(out region)" --secret-id "$(out rds_master_secret_arn)" --query SecretString --output text)
  PGPASSWORD=$(jq -r .password <<<"$secret") psql \
    "host=$(out rds_address) hostaddr=127.0.0.1 port=15432 dbname=labdb user=$(jq -r .username <<<"$secret") sslmode=verify-full sslrootcert=$(rds_ca)" \
    "$@"
}
cmd_db_bootstrap() { psql_master --single-transaction -v ON_ERROR_STOP=1 -f db/bootstrap.sql; }
cmd_db_shell() { psql_master; }

# Writes this environment's Terraform outputs into gitops/apps/values.yaml for you
# to review and commit. Pairs are values-key=terraform-output.
cmd_gitops_env() {
  local file=gitops/apps/values.yaml pair
  VALUE=$(git remote get-url origin) yq -i '.repoURL = strenv(VALUE)' "$file"
  for pair in region=region clusterName=cluster_name vpcId=vpc_id vpcCidr=vpc_cidr \
    ecrRegistry=ecr_registry rdsAddress=rds_address dbAppUser=db_app_user \
    certificateArn=certificate_arn zone=zone_name caCert=certificate_pem \
    clusterSecurityGroupId=cluster_primary_security_group_id \
    dbClientSecurityGroupId=db_client_security_group_id lbcRoleArn=lbc_role_arn \
    externalDnsRoleArn=external_dns_role_arn backendRoleArn=backend_role_arn; do
    VALUE=$(out "${pair#*=}") yq -i ".${pair%%=*} = strenv(VALUE)" "$file"
  done
  echo "Wrote $file. Review and commit it; Argo CD reads it from Git."
}

cmd_bootstrap() {
  local repo zone
  repo=$(git remote get-url origin)
  zone=$(out zone_name)

  k create namespace monitoring --dry-run=client -o yaml | k apply -f -
  k -n monitoring get secret grafana-admin >/dev/null 2>&1 ||
    k -n monitoring create secret generic grafana-admin \
      --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 24)"

  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm --kube-context "$CONTEXT" upgrade --install argocd argo/argo-cd --version 10.10.5 \
    --namespace argocd --create-namespace -f gitops/argocd/values.yaml \
    --set "server.ingress.hostname=argocd.$zone" --wait --timeout 15m

  # Private repository: DEPLOY_KEY=path/to/read-only-deploy-key make bootstrap
  if [[ -n ${DEPLOY_KEY:-} ]]; then
    k -n argocd create secret generic repo-lab-commit --from-literal=type=git \
      --from-literal=url="$repo" --from-file=sshPrivateKey="$DEPLOY_KEY" --dry-run=client -o yaml |
      k label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | k apply -f -
  fi

  REPO_URL=$repo envsubst '$REPO_URL' <gitops/root.yaml | k apply -f -
  wait_converged
}

# Done only when every expected Application exists and is Synced + Healthy; a
# missing one counts as not converged.
wait_converged() {
  local deadline=$((SECONDS + 900)) app state pending
  while :; do
    pending=()
    for app in "${EXPECTED_APPS[@]}"; do
      state=$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo missing)
      [[ $state == Synced/Healthy ]] || pending+=("$app=$state")
    done
    if ((${#pending[@]} == 0)); then
      echo "All Applications Synced/Healthy."
      return 0
    fi
    ((SECONDS < deadline)) || { echo "Not converged after 15m: ${pending[*]}"; return 1; }
    echo "Waiting: ${pending[*]}"
    sleep 20
  done
}

# Run before `terraform destroy`. The load balancer controller owns the ALB and its
# security groups, so they must go while it still runs - otherwise destroy fails
# with DependencyViolation on the subnets and VPC.
cmd_teardown_k8s() {
  confirm "Delete every Argo CD Application and the ALB on context $CONTEXT?" || return 1

  local app
  for app in "${EXPECTED_APPS[@]}"; do # stop reconciliation so nothing is recreated
    k -n argocd patch application "$app" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
  done

  k -n argocd delete application lab-commit --ignore-not-found --wait --timeout 10m
  k -n monitoring delete ingress --all --ignore-not-found
  k -n argocd delete ingress --all --ignore-not-found
  wait_lb_resources_gone

  for app in external-dns keda kube-prometheus-stack aws-load-balancer-controller root; do
    k -n argocd delete application "$app" --ignore-not-found --wait --timeout 10m
  done
  helm --kube-context "$CONTEXT" uninstall argocd --namespace argocd || true
}

wait_lb_resources_gone() {
  local deadline=$((SECONDS + 600)) left
  while :; do
    left=$(aws resourcegroupstaggingapi get-resources --region "$(out region)" \
      --resource-type-filters elasticloadbalancing:loadbalancer elasticloadbalancing:targetgroup ec2:security-group \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$(out cluster_name)" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text)
    [[ -z $left ]] && return 0
    ((SECONDS < deadline)) || { echo "Still present after 10m: $left"; return 1; }
    echo "Waiting for the load balancer controller to delete: $left"
    sleep 15
  done
}

cmd="cmd_${1:-}"
cmd=${cmd//-/_}
if ! declare -F "$cmd" >/dev/null; then
  echo "usage: $0 {init|delete-default-vpc|tunnel-eks|kubeconfig|tunnel-db|db-bootstrap|db-shell|gitops-env|bootstrap|teardown-k8s}" >&2
  exit 2
fi
"$cmd"
