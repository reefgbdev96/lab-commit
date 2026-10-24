# Lab-Commit — EKS on Fargate, GitOps, autoscaling

A private, HTTPS-only application on EKS 1.36, built with Terraform. A Go frontend
shows its own build version plus a value it polls from a Go backend every 5 seconds;
the backend reads it from RDS PostgreSQL. CodePipeline builds new versions, Argo CD
deploys them, KEDA scales the frontend on request rate, and a Windows jump box
reached only through SSM is the one way in.

```
                       AWS account (one region)            VPC 10.0.0.0/16
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │  public subnet (NAT gateway only — nothing runs here)                        │
 │                                                                              │
 │  private subnets (2 AZs)                                                     │
 │   Windows jump box ──HTTPS──▶ internal ALB ──▶ frontend pods ──▶ backend pods │
 │   (SSM only, no key pair)    (TLS 1.3, VPC-only)  (KEDA 1–4)     (IRSA + IAM  │
 │                               │                                    DB auth)  │
 │                               ├─▶ Grafana    ◀── Prometheus                   │
 │                               └─▶ Argo CD    ◀── Git (GitHub)        │       │
 │   EKS 1.36, Fargate only, private API endpoint                     RDS PG17  │
 │   Route 53 private zone lab.internal (external-dns)                (private) │
 └──────────────────────────────────────────────────────────────────────────────┘
  GitHub push ─▶ CodePipeline ─▶ CodeBuild ─▶ ECR (immutable) + tag commit ─▶ Argo CD
```

## How each requirement is met

| Requirement | Implementation |
|---|---|
| Assume a privileged role | Run Terraform and `make` with that role's credentials (`AWS_PROFILE`). |
| VPC + 2 private subnets, delete the default VPC | `terraform/modules/network`; `make delete-default-vpc` (asks first). One public subnet exists only for the NAT gateway. |
| Routes, limited security-group ports | Private route tables → NAT; S3 gateway endpoint. RDS accepts 5432 only from the `db-client` SG (backend pods) and the jump box; the EKS API accepts 443 only from the jump box; the ALB accepts 443 only from the VPC; the jump box has no inbound rule at all. |
| EKS 1.36, private subnets only, **no node groups** | `terraform/modules/eks`: Fargate profiles only — no managed, self-managed or Auto Mode nodes. Private API endpoint. |
| Load balancer controller (ALB) | AWS Load Balancer Controller installed by Argo CD (`gitops/apps/templates/aws-lbc.yaml`), IRSA role from Terraform. |
| SSL termination on the ALB, self-signed cert | `terraform/modules/dns-tls` generates an X.509 v3 cert (ACM rejects v1) and imports it into ACM; `IngressClassParams` pins it with TLS 1.3. |
| A CD tool on the cluster | Argo CD, app-of-apps in `gitops/`. |
| App in any language, Helm 3 | Go services in `apps/`, chart in `charts/lab-commit`. |
| Page shows "Hello Lab-Commit X", secured URL only | `Hello Lab-Commit <apps/frontend/VERSION> (db: 5)` at `https://Lab-commit-task.lab.internal` — HTTPS listener only, no port 80. |
| RDS, backend queries it, frontend polls every 5 s | `SELECT value FROM messages WHERE id = 1`; the frontend caches it and the page refreshes every 5 s. |
| Not exposed to the internet | Internal ALB, private hosted zone, private EKS endpoint, no public IPs. |
| Route 53 record `Lab-commit-task.<zone>` | external-dns creates it from the Ingress (DNS is case-insensitive; Kubernetes requires lowercase hosts). |
| Windows EC2 via SSM, no key pair, browse with Chrome | `terraform/modules/windows-jumpbox`: Chrome installed and the lab certificate trusted at boot. |
| Monitoring without the CloudWatch agent, CPU/memory visible | kube-prometheus-stack; Grafana at `https://grafana.lab.internal`. |
| Dashboard with pod counts for frontend and backend | `charts/lab-commit/dashboards/lab-commit.json` (also request rate, CPU, memory). |
| Load generator via Web | `apps/loadgen` drives `https://lab-commit-task.lab.internal/` through the ALB, verifying TLS. |
| >10 req/s adds a frontend pod, up to 4, then scales down | KEDA on `sum(rate(http_requests_total[1m]))`, 10 req/s per pod, min 1, max 4; loadgen ramps 15 → 25 → 35 req/s (2 → 3 → 4 pods) then pauses (back to 1, one pod per 30 s). |
| Code in GitHub, pipeline deploys new frontend versions | `terraform/modules/pipeline` + `ci/buildspec.yml`; bump `apps/frontend/VERSION` to `v1.0.1` and push. |
| Infrastructure in Terraform | Every AWS resource is in `terraform/`. In-cluster software is GitOps (`gitops/`, applied by Argo CD; external-dns writes the Route 53 records), the DB schema and role are `db/bootstrap.sql`, and `scripts/ops.sh` does the one-off bootstrap (Argo CD install, Grafana admin secret, default-VPC deletion). |

## Design decisions

- **Fargate, not EKS Auto Mode.** Auto Mode has no node groups either, but its
  Karpenter NodePools could be read as one; Fargate is unambiguous. Consequences:
  we install the LB controller ourselves, workloads use IRSA (Fargate has no Pod
  Identity), and pod CPU/memory is scraped through the API-server proxy because
  Fargate kubelets are not reachable from pods.
- **NAT gateway instead of a fully isolated VPC.** Workloads stay in private
  subnets and nothing accepts inbound traffic; the NAT only carries egress (image
  pulls, GitHub). Fully isolated would need ~10 interface endpoints (~$146/month
  vs ~$33) and mirroring every chart and image into ECR.
- **Self-signed certificate.** ACM cannot validate names in a private zone. The
  production alternative is a public zone used only for ACM validation, with the
  record itself in the private zone (split-horizon), giving a free, auto-renewing,
  browser-trusted certificate.
- **No database password in the application.** The backend logs in as `lab_app`
  with 15-minute RDS IAM tokens (IRSA role allowed `rds-db:connect` for that user
  only). `lab_app` can only `SELECT`. Backend pods carry the `db-client` security
  group through a `SecurityGroupPolicy` — the only pods RDS admits. The master
  password is RDS-managed and rotates every 7 days; only `make db-bootstrap` uses it.
- **CI never touches the cluster or the database.** CodeBuild pushes an immutable
  image tagged `<VERSION>-<commit>` and commits that tag to `gitops/images/`; Argo
  CD deploys it. The write-back uses a fine-grained PAT limited to this repository
  — not the CodeConnections token, which covers every repository the GitHub App can
  see. A retried build reuses the image and only finishes the commit.
- **Operator access through the jump box.** The API endpoint is never public:
  `make tunnel-eks` port-forwards it over SSM; `make tunnel-db` does the same for
  RDS. Session Manager is outbound-only, so the jump box has no inbound port.
- **Autoscaling math.** KEDA's `AverageValue` sets replicas to
  `ceil(total req/s ÷ 10)`. The loadgen steps sit well outside the HPA's default
  10% tolerance, so each step moves exactly one pod.
- **Managed Argo CD (EKS Capabilities) considered:** it runs outside the cluster,
  and the requirement says "on the cluster".

## Security and least privilege

| Control | Where |
|---|---|
| Nothing reachable from the internet: private subnets, internal ALB, private hosted zone, private EKS API, no public IPs | `modules/network`, `modules/eks`, `gitops/apps/templates/platform.yaml` |
| Ingress pinned at the class: `scheme: internal`, HTTPS only, TLS 1.3 policy, VPC CIDR only | `gitops/apps/templates/platform.yaml` |
| Security groups allow one hop each: VPC → ALB 443, jump box → EKS API 443, `db-client` pods + jump box → RDS 5432; the jump box has no inbound rule | `modules/rds`, `modules/eks`, `modules/windows-jumpbox` |
| One IAM role per workload (IRSA), trusted only by its own service account: LB controller, external-dns (one private zone), backend (`rds-db:connect` as `lab_app` only) | `envs/lab/irsa.tf` |
| No database password in the app: 15-minute IAM tokens over verified TLS (`sslmode=verify-full`), refused otherwise; `lab_app` is SELECT-only; master password RDS-managed and rotated | `apps/backend/db.go`, `db/bootstrap.sql`, `modules/rds` |
| Pod-level DB access: only backend pods get the `db-client` security group (SecurityGroupPolicy) | `charts/lab-commit/templates/backend.yaml` |
| Pods: restricted Pod Security Standard, non-root (UID 65532), read-only root filesystem, all capabilities dropped, no service-account token unless needed, distroless images | `charts/lab-commit`, `apps/*/Dockerfile` |
| CI cannot touch the cluster or the database; build role limited to its 3 ECR repositories and one secret; confused-deputy guard on service roles; write-back PAT scoped to this repository | `modules/pipeline`, `ci/buildspec.yml` |
| Jump box: no key pair, IMDSv2 only, encrypted disk, SSM-only access; Fargate pod roles without the CNI policy | `modules/windows-jumpbox`, `modules/eks` |
| State: encrypted, versioned, TLS-only S3 bucket with native locking | `terraform/bootstrap` |

## Prerequisites

- An AWS account and a role with administrator access.
- Terraform ≥ 1.16, AWS CLI v2 with the
  [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
  kubectl, Helm 3, jq, yq, psql.
- This code in a GitHub repository, plus a fine-grained personal access token with
  **Contents: read and write on this repository only** (for the pipeline), and —
  if the repository is private — a read-only deploy key for Argo CD.

## Deploy

Run from the repository root. The region defaults to eu-west-1. CLI sign-in is
`aws login --region eu-west-1` (browser sign-in, temporary credentials — no access
keys on disk).

1. Bootstrap, as your IAM user — the state bucket plus a dedicated admin role:
   `terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply -var operator_user=<your-iam-user>`
   then add the role profile to `~/.aws/config` and use it from here on:
   ```ini
   [profile commit-login]
   # Terraform's SDK cannot assume a role from an `aws login` session; the CLI can.
   credential_process = aws configure export-credentials --profile default --format process

   [profile commit]
   role_arn          = <operator_role_arn output>
   source_profile    = commit-login
   role_session_name = <your-iam-user>
   region            = eu-west-1
   ```
   `export AWS_PROFILE=commit` and check `aws sts get-caller-identity`. Terraform,
   kubectl and the tunnels all use this profile and refresh it themselves.
2. `cp terraform/envs/lab/terraform.tfvars.example terraform/envs/lab/terraform.tfvars`
   and set `github_repository`.
3. `make init`, then `terraform -chdir=terraform/envs/lab apply`.
   Then `make delete-default-vpc` (asks first).
4. In the AWS console, open **CodePipeline → Settings → Connections**, choose the pending
   `lab-commit` connection and **Update pending connection** to install the GitHub App.
5. Store the PAT. It's read silently and piped, so it never lands in shell history,
   a file, or a process argument list:
   `read -rs PAT && printf '%s' "$PAT" | aws secretsmanager put-secret-value --secret-id lab-commit/github-token --secret-string file:///dev/stdin; unset PAT`
6. Start each pipeline once so every image exists:
   `for s in frontend backend loadgen; do aws codepipeline start-pipeline-execution --name lab-commit-$s; done`
7. In one terminal `make tunnel-db`; in another `make db-bootstrap`.
8. In one terminal `make tunnel-eks`; in another `make kubeconfig`.
9. `make gitops-env`, review `gitops/apps/values.yaml`, commit and push.
10. `DEPLOY_KEY=~/.ssh/<read-only deploy key> make bootstrap` — Argo CD clones over SSH. It
    installs Argo CD and waits until all six Applications are Synced and Healthy.

## Review it

**Connect to the jump box.** Set a password for the built-in Administrator from a
Session Manager shell, then RDP through an SSM port-forward:

```sh
aws ssm start-session --target "$(terraform -chdir=terraform/envs/lab output -raw jumpbox_instance_id)"
#   PS> Set-LocalUser -Name Administrator -Password (Read-Host -AsSecureString "New password")
aws ssm start-session --target "$(terraform -chdir=terraform/envs/lab output -raw jumpbox_instance_id)" \
  --document-name AWS-StartPortForwardingSession --parameters portNumber=3389,localPortNumber=13389
#   then RDP to localhost:13389 as Administrator
```

In Chrome on the jump box:

- `https://Lab-commit-task.lab.internal` — `Hello Lab-Commit <VERSION> (db: 5)`, a
  valid padlock (the lab certificate is trusted at boot), refreshing every 5 s.
- `https://grafana.lab.internal` — dashboard **Lab-Commit**: pods, request rate,
  CPU and memory. The load generator loops every ~15 minutes, so the frontend
  climbs 1 → 2 → 3 → 4 and steps back to 1. Stop the load with
  `kubectl --context lab-commit -n demo scale deploy/loadgen --replicas=0` (Argo CD
  self-heal restores it within minutes; set `loadgen.enabled: false` to keep it off).
- `https://argocd.lab.internal` — user `admin`, password from
  `kubectl --context lab-commit -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

**Pipeline demo:** set `apps/frontend/VERSION` to `v1.0.1` and push. The frontend
pipeline builds `v1.0.1-<sha>`, commits the tag, and Argo CD rolls it out; the page
then reads `Hello Lab-Commit v1.0.1 (db: 5)`.

**Database demo:** `make tunnel-db`, then `make db-shell` and
`UPDATE messages SET value = '6' WHERE id = 1;` — the page shows `(db: 6)` within 5 s.

**Not exposed:** from your laptop, `Lab-commit-task.lab.internal` does not resolve,
the EKS endpoint has no public access, and no instance or pod has a public IP.

**Verified live** (eu-west-1, October 2026)

| Check | Result |
|---|---|
| Page over HTTPS via the internal ALB | `HTTP/2 200`, `Refresh: 5`, certificate verifies against the lab CA, TLS 1.3 |
| DB change reaches the page | 3 s after `UPDATE` (poll interval 5 s) |
| Scaling | 35 req/s → 4 frontend pods within ~70 s; load stops → back to 1 within ~70 s |
| Pipeline `v1.0.1` | push → webhook → build 2m41s → tag commit → page shows `v1.0.1` after ~5.5 min; pod digest = ECR digest |
| Jump box | Chrome installed, lab CA trusted, `lab-commit-task.lab.internal` resolves to the ALB's private IPs |

**Acceptance checks**

- Displayed version = `apps/frontend/VERSION`; the deployed tag is
  `<VERSION>-<commit>`; the pod `imageID` digest equals the ECR digest.
- `kubectl --context lab-commit -n argocd get applications` — all Synced/Healthy.
- `lab_app` can read `messages` but not write it.
- Backend pods' ENIs carry the `db-client` security group.

## Tear down

1. `make teardown-k8s` (with `make tunnel-eks` running) — stops Argo CD
   reconciliation, deletes the Ingresses while the LB controller still runs, waits
   until the ALB and its security groups are gone, then removes the controllers.
   Skipping this makes `terraform destroy` fail with DependencyViolation.
2. `terraform -chdir=terraform/envs/lab destroy`.
3. Empty and delete the state bucket, then `terraform -chdir=terraform/bootstrap destroy`.

## Cost

About $12.50 per day in eu-west-1 while running (EKS control plane $0.10/h, ~19
Fargate pods ~$0.32/h, NAT $0.05/h, ALB $0.03/h, RDS $0.02/h), plus ~$1.50 for each
day the Windows jump box runs — stop it when idle
(`aws ec2 stop-instances --instance-ids <id>`). Destroy everything after review.

## Develop locally

```sh
make check   # tidy, build, -race tests, lint, govulncheck, fmt, terraform validate, helm lint
make e2e     # kind cluster: restricted PSS, Prometheus, KEDA 1 → 4 → 1, DB round trip (needs Docker)
```

## Security notes and next steps

- The operator role carries AdministratorAccess: Terraform here creates IAM roles,
  OIDC providers, EKS, RDS and networking, so a scoped policy would be nearly as broad.
  It is assumable only by the named IAM user with a fixed session name; a permissions
  boundary limited to `lab-commit*` resources is the next step.
- The self-signed TLS private key is in Terraform state — kept in the encrypted,
  versioned, TLS-only S3 backend, never in Git or outputs. Imported certificates do
  not auto-renew: re-apply before the 365-day expiry.
- The lab account is shared with other candidates: account-global names (IAM roles,
  the state bucket) use generated suffixes or the region, nothing account-wide is
  changed, and `tags = { Owner = ... }` marks every resource.
- Grafana allows anonymous read-only access (internal network only); admin uses a
  random password generated at bootstrap.
- Next steps: Kubernetes NetworkPolicy, VPC flow logs, digest-pinned base images,
  a NAT gateway per AZ.
