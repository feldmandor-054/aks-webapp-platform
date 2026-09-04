# aks-webapp-platform

Production-oriented deployment of a small containerized web service on **Azure Kubernetes Service**, built for a
3-hour DevOps home assignment. Everything is code: Terraform for infrastructure, Helm for the workload, GitHub
Actions for CI/CD, OIDC for identity. No secrets are stored anywhere.

> **Live (dev):** region `israelcentral`, endpoints `/`, `/healthz`, `/readyz`, `/metrics`.
> The address is deliberately not written down here: it belongs to the ingress controller's `LoadBalancer`
> Service and is allocated by Azure per cluster, so it changes whenever the cluster is rebuilt. To get the
> current one:
>
> ```bash
> # from the pipeline - the Deploy run's environment URL and job summary carry it
> gh run view --workflow Deploy --json jobs --jq '.jobs[].steps[].name' # or open the run in the UI
>
> # or straight from the cluster
> kubectl -n dev get ingress webapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
> ```
>
> The cluster is destroyed when not in use (`scripts/teardown.sh`), so it may not be running when you read
> this; the pipeline recreates everything from scratch in ~12 minutes. Giving the endpoint a stable name
> (reserved static IP, or a DNS zone attached to the app-routing add-on) is listed in §9.

---

## 1. Architecture

Full diagrams and decision tables: **[docs/architecture.md](docs/architecture.md)**.

```
 push/PR ──► CI (ruff · pytest · helm lint · docker build · Trivy) ──► ghcr.io/<owner>/webapp:sha-xxxx
                                                                          │
                     ┌────────────────────────────────────────────────────┘
                     ▼
        Deploy (helm upgrade --atomic) ──► cluster aks-webapp-dev, namespace dev ──► managed NGINX ingress ──► public IP
                     ▲
        manual dispatch env=prod tag=sha-xxxx (GitHub Environment approval) ──► cluster aks-webapp-prod
        same image, values-prod.yaml                                            = promotion / rollback

 Terraform (plan on PR, apply on main w/ approval) ──► rg-webapp-<env>: VNet · AKS (Free, 1×B2als_v2→2) · Log Analytics
                                                       one cluster per environment; only dev is applied (cost)
 Identity: GitHub OIDC ──► Entra SP "infra" (Owner on RG)  /  Entra SP "deploy" (AKS RBAC only)
```

### Environments

"Environment" means three distinct things here, and they are deliberately kept aligned by name:

| Layer | `dev` | `prod` | Defined in |
|---|---|---|---|
| **Terraform environment** — own state file, own resource group, **own AKS cluster** | `rg-webapp-dev` / `aks-webapp-dev` — applied | `rg-webapp-prod` / `aks-webapp-prod` — defined, *not applied* (cost) | `infra/envs/<env>/` (identical `*.tf`; only `terraform.tfvars` + `backend.hcl` differ) |
| **Kubernetes namespace** inside that cluster, labelled PSA `restricted` | `dev` | `prod` | created by `deploy.yml` |
| **GitHub Environment** — protection rules + OIDC federated subject | no reviewer: merges to `main` deploy automatically | **required reviewer** — this is the promotion gate | GitHub repo settings; subjects created by `bootstrap.sh` |

The same chart serves both; only `charts/webapp/values-<env>.yaml` differs (replicas, resources, HPA/PDB
bounds, hard vs soft topology spread, hostname + TLS, dedicated node pool). Templates never fork per
environment, so there is no environment-specific code path that can rot unnoticed — and `helm template`
renders **both** values files in CI on every commit, which is what keeps the unapplied prod path honest.

Because the prod GitHub Environment gates the OIDC token whose subject is `...:environment:prod`, the
human approval and the credential to reach prod are the *same* gate: no approval, no Azure token.

### What runs where

| Layer | Choice | Notes |
|---|---|---|
| App | FastAPI (`app/`) | `/healthz` liveness, `/readyz` readiness, `/metrics` Prometheus. Multi-stage image, non-root UID 10001 |
| Cluster | AKS Free tier, Azure CNI overlay, Entra ID + Azure RBAC, local accounts **disabled**, OIDC issuer + Workload Identity on | `infra/modules/aks` |
| Nodes | 1× `Standard_B2als_v2` (2 vCPU/4 GiB) with cluster autoscaler 1→2 (dev); 3× D2s system + D4s user pool across 3 AZs (prod tfvars) | Cost-driven for dev; SKU chosen from what the free subscription allows in the region |
| Ingress | AKS application-routing add-on (managed NGINX) + Standard LB | No extra Helm installs to maintain |
| Registry | GitHub Container Registry, public | Free; ACR with private endpoint is the prod recommendation |
| Logs/metrics | Container Insights → Log Analytics; app exposes Prometheus metrics | Managed Prometheus/Grafana is the next step |
| State | Azure Blob, versioned + soft-delete, **Entra-only auth** (shared keys disabled) | Created by `infra/bootstrap/bootstrap.sh` |

## 2. Repository layout

```
app/                       FastAPI service, tests, Dockerfile
charts/webapp/             Helm chart; values-dev.yaml / values-prod.yaml hold env deltas only
infra/modules/network      VNet, subnet, NSG                      ─┐ reusable
infra/modules/aks          AKS, identity, Log Analytics, RBAC       │ infrastructure
infra/modules/platform     composition: network + aks               ─┘
infra/envs/dev, prod       root modules: identical *.tf; only terraform.tfvars + backend.hcl differ
infra/bootstrap/           one-time: state storage, resource groups, Entra apps + GitHub OIDC federation
.github/workflows/ci.yml        lint → test → build → scan → push → deploy dev
.github/workflows/deploy.yml    reusable + manual: helm upgrade --atomic, smoke test, auto-rollback
.github/workflows/terraform.yml plan on PR (commented), apply after environment approval
scripts/rollback.sh        break-glass helm rollback
docs/architecture.md       diagrams + decision records
```

## 3. Deploying from zero

Prerequisites: `az`, `terraform >= 1.6`, `gh`, `helm`, `kubectl`, `kubelogin`; an Azure subscription where you are Owner; a GitHub repo.

```bash
# 1. One-time bootstrap (human, Owner): providers, RGs, state storage, OIDC identities. Creates NO secrets.
az login
GITHUB_REPO=<owner>/<repo> LOCATION=israelcentral bash infra/bootstrap/bootstrap.sh
#    -> writes infra/envs/{dev,prod}/backend.hcl (commit them) and prints `gh variable set ...` lines (run them)

# 2. GitHub environments: create `dev` and `prod`; give `prod` a required reviewer.
gh api -X PUT repos/<owner>/<repo>/environments/dev
gh api -X PUT repos/<owner>/<repo>/environments/prod -f 'reviewers[][type]=User' -F 'reviewers[][id]=<your-user-id>'

# 3. Infrastructure: push to main -> Terraform workflow plans, then applies after approval (≈10 min).
#    Or locally:
set -a; source infra/bootstrap/bootstrap.out.env; set +a
export ARM_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID ARM_TENANT_ID=$AZURE_TENANT_ID ARM_USE_AZUREAD=true
terraform -chdir=infra/envs/dev init -backend-config=backend.hcl
terraform -chdir=infra/envs/dev apply

# 4. Application: any push to main builds, scans and deploys to dev automatically.
#    Promote to prod: Actions -> Deploy -> Run workflow -> environment=prod, image_tag=sha-xxxxxxxxxxxx

# 5. kubectl for humans (Entra RBAC):
az aks get-credentials -g rg-webapp-dev -n aks-webapp-dev && kubelogin convert-kubeconfig -l azurecli
kubectl -n dev get pods,svc,ingress,hpa,pdb

# Tear down: see §3a
```

### 3a. Tearing down — what costs money and how to remove it

| Resource | Created by | Cost while it exists | Removed by |
|---|---|---|---|
| AKS node VM(s) `Standard_B2als_v2` + 32 GB OS disk | Terraform | ~$0.04/h per node (~$1/day) | `terraform destroy` |
| Standard Load Balancer + public IP (ingress) | AKS add-on | ~$0.005/h + LB rules | `terraform destroy` (deleted with the cluster's `MC_*` node resource group) |
| Log Analytics workspace | Terraform | first 5 GB/month free, then per GB | `terraform destroy` |
| AKS control plane (Free tier), VNet, NSG, managed identity, role assignments | Terraform | $0 | `terraform destroy` |
| Terraform state storage account (LRS, a few KB) | bootstrap | < $0.05/month | `az group delete -n rg-webapp-tfstate` |
| Resource groups `rg-webapp-dev/prod` (empty after destroy) | bootstrap | $0 | `az group delete` |
| Entra applications (OIDC identities) | bootstrap | $0 | `az ad app delete` |
| GHCR images, GitHub Actions minutes | CI | $0 (public repo) | delete packages in GitHub UI if desired |

```bash
# Option A - one command (recommended):
scripts/teardown.sh            # destroys the dev environment: everything billable is gone
scripts/teardown.sh --all      # ...and also the resource groups, state storage and Entra apps

# Option B - through the pipeline (auditable): Actions -> Terraform -> Run workflow -> environment=dev, action=destroy

# Option C - manual equivalent of Option A:
set -a; source infra/bootstrap/bootstrap.out.env; set +a
export ARM_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID ARM_TENANT_ID=$AZURE_TENANT_ID ARM_USE_AZUREAD=true
terraform -chdir=infra/envs/dev destroy
for rg in rg-webapp-dev rg-webapp-prod rg-webapp-tfstate; do az group delete -n $rg --yes --no-wait; done   # only if finished for good
az ad app delete --id $AZURE_INFRA_CLIENT_ID; az ad app delete --id $AZURE_DEPLOY_CLIENT_ID

# Verify nothing billable remains:
az resource list --query "[?type!='Microsoft.Storage/storageAccounts'].{name:name,type:type,rg:resourceGroup}" -o table
az group list -o table          # MC_rg-webapp-dev_* must be gone; it holds the VMs, disks, LB and IP
```

Set a budget alert while the cluster is up: **Cost Management → Budgets** (e.g. $5/month, alert at 80 %).

### 3b. Evidence from a real run

Reproduce any of this against a running cluster — `$INGRESS_IP` is resolved, never hardcoded:

```bash
INGRESS_IP=$(kubectl -n dev get ingress webapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

```text
$ curl -s "http://$INGRESS_IP/"
{"service":"webapp","version":"sha-<git-sha>","environment":"dev","hostname":"webapp-<pod>","message":"Hello world"}   [200, ~13 ms]

$ kubectl -n dev get deploy,ingress,hpa,pdb
deployment.apps/webapp              2/2     2            2
ingress.networking.k8s.io/webapp    webapprouting.kubernetes.azure.com   *   <ingress-ip>   80
horizontalpodautoscaler/webapp      Deployment/webapp   cpu: 1%/70%   2   3
poddisruptionbudget/webapp          MIN AVAILABLE 1

$ kubectl get ns dev -o jsonpath='{.metadata.labels}'
{"pod-security.kubernetes.io/enforce":"restricted","pod-security.kubernetes.io/warn":"restricted"}

$ kubectl -n dev get pod -l app.kubernetes.io/name=webapp -o jsonpath='{.items[0].spec.containers[0].securityContext}'
{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}

# Rollback by tag: Deploy workflow dispatched with an earlier image tag.
# The smoke test asserts the *served* version equals the requested tag, so a silent no-op fails the job.
$ helm -n dev history webapp
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete      (newer tag)
2         deployed    Upgrade complete      (earlier tag - the rollback)
```

Pipeline runs: [Terraform apply (12 added)](../../actions/workflows/terraform.yml) ·
[CI build → scan → push → deploy](../../actions/workflows/ci.yml) · [Deploy (rollback by tag)](../../actions/workflows/deploy.yml).

## 4. CI/CD: build once, promote by tag, roll back by tag

**Pipeline stages (`ci.yml`)**: `ruff` + `pytest` → `helm lint --strict` + template render → `docker build` (buildx, GHA cache)
→ **Trivy** scan, fails on fixable HIGH/CRITICAL → push `ghcr.io/<owner>/webapp:sha-<12>` (+ `latest`) → call `deploy.yml` for `dev`.
PRs run everything except the push/deploy.

**Artifact promotion**: the image is built exactly once and identified by an immutable `sha-` tag. Promotion to
prod is the *same tag* deployed with `values-prod.yaml` through the `prod` GitHub Environment, which requires a
reviewer. Nothing is rebuilt, so what was tested is what ships.

**Rollback** (three layers):
1. `helm upgrade --atomic --wait` — if pods never become Ready, Helm reverts the release automatically.
2. Post-deploy smoke test through the ingress checks `/`, `/healthz`, `/readyz` **and that the served version equals
   the requested tag**; on failure the workflow runs `helm rollback` and fails the job.
3. Human rollback = re-run **Deploy** with the last known-good `sha-` tag (auditable, gated) or, break-glass,
   `scripts/rollback.sh <env> [revision]`.

**Infra changes (`terraform.yml`)**: `fmt`/`validate`/`plan` on every PR with the plan posted as a comment; on
merge to `main` the *saved plan* is applied after `dev` environment approval. `workflow_dispatch` supports
`plan`/`apply`/`destroy` per environment.

## 5. Security

**Identities & secrets**

- CI authenticates with **GitHub OIDC → Entra federated credentials**. Two service principals with disjoint rights:
  `gh-*-infra` (Owner on `rg-webapp-dev`/`-prod` and Blob Data Contributor on the state account) and `gh-*-deploy`
  (only `AKS Cluster User` + `AKS RBAC Cluster Admin` on the cluster, granted by Terraform). No client secrets exist;
  federated subjects are pinned to `main`, `pull_request` and the `dev`/`prod` environments.
- AKS: **local accounts disabled**, Entra ID + Azure RBAC for all `kubectl`/Helm access; control plane uses a
  user-assigned managed identity with `Network Contributor` on its subnet only.
- Terraform state: Entra-only auth (`--allow-shared-key-access false`), versioning + soft delete.
- The app has no secrets. For real ones: Key Vault + Secrets Store CSI driver / External Secrets with a per-service
  Workload Identity (issuer already enabled). Repo variables hold only IDs; `.gitignore` blocks tfvars/state/kubeconfig.
- Workload hardening: `runAsNonRoot` UID 10001, read-only root FS, all capabilities dropped, seccomp `RuntimeDefault`,
  no service-account token mount, namespace labelled **Pod Security Admission `restricted`**.

**Risks considered**

| # | Risk | Mitigation here | Next step |
|---|---|---|---|
| 1 | Leaked long-lived cloud credentials in CI | OIDC federation, no secrets to leak; least-privilege split identities | Branch protection so only reviewed code runs with `main` subject |
| 2 | Vulnerable base image / dependency | Slim pinned base, pinned requirements, Trivy gate blocks HIGH/CRITICAL, SARIF to Security tab | Dependabot, cosign signing + admission policy, digest pinning |
| 3 | Container breakout / privilege escalation | Non-root, RO fs, drop ALL, PSA `restricted`, no SA token | NetworkPolicy default-deny, Defender for Containers |
| 4 | Public API server & lateral movement | Entra RBAC only, `authorized_ip_ranges` variable ready (set in prod tfvars) | Private cluster + Bastion/self-hosted runners |
| 5 | Mutable tags / "works on my rebuild" drift | Deploy by immutable `sha-` tag, same artifact promoted | Deploy by digest; provenance attestations |
| 6 | Terraform state exposure | Entra-only storage, versioned, separate RG | Private endpoint for the storage account |

## 6. Observability & troubleshooting

**Monitoring**: Container Insights ships container logs, events and node/pod metrics to Log Analytics; the app
exposes RED metrics (`http_requests_total`, `http_request_duration_seconds` histogram) with Prometheus scrape
annotations. Production adds Managed Prometheus + Grafana dashboards per service and alerts on **SLO burn rate**
(p95/p99 latency, 5xx ratio) — not on CPU. Ingress controller metrics give per-route latency without touching the app.

### Scenario: pods Running/Ready, CPU ~35 %, memory ~55 %, no deployment, latency 200 ms → 5 s

*Mental model*: the pods are healthy and not saturated on the metrics we look at, so the time is being spent
**waiting** — on a dependency, on the network, or on a resource we are not measuring. "No recent deployments" does not
mean "no change".

**Order of investigation**

1. **Scope and timeline (2 min).** Which endpoints/tenants? All pods or some? When exactly did it start?
   Ingress logs / Container Insights: `p95 by route`, error rate. Correlate with anything at that timestamp.
   ```bash
   kubectl -n dev get events -A --sort-by=.lastTimestamp | tail -50
   kubectl -n app-routing-system logs deploy/nginx --since=30m | awk '{print $NF}' | sort -n | tail   # upstream_response_time
   ```
2. **Rule out silent changes.** ConfigMap/Secret edits, HPA scale events, **AKS auto-upgrade / node image upgrade**,
   certificate rotation, DNS/feature-flag changes, a dependency's own deployment.
   `kubectl rollout history`, `kubectl get cm -o yaml | grep -i resourceVersion`, Azure Activity Log for the cluster.
3. **Dependencies (most likely culprit).** For each downstream (DB, cache, queue, third-party API): latency and
   saturation from *its* side. PostgreSQL: `pg_stat_activity` (waits, idle-in-transaction, lock chains),
   `pg_stat_statements` top by mean time, connection-pool exhaustion (app waits for a free connection = latency, not
   CPU). Redis: `SLOWLOG`, `evicted_keys`, big keys. RabbitMQ: queue depth, unacked, consumer utilisation.
   ```bash
   kubectl -n dev exec deploy/webapp -- sh -c 'time nslookup postgres.example'   # DNS
   kubectl -n dev run dbg --rm -it --image=nicolaka/netshoot -- curl -w '%{time_connect} %{time_starttransfer}\n' -o /dev/null -s http://webapp/readyz
   ```
4. **Platform-level, things averages hide.**
   - **CPU throttling**: 35 % average with a tight `limits.cpu` can still throttle bursts →
     `container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total`, `kubectl top pod --containers`.
   - **CoreDNS**: latency/`SERVFAIL`, `ndots:5` amplification, conntrack table full on the node (`kubectl debug node/…`, `conntrack -S`).
   - **Node** disk I/O wait (logging burst), network saturation, noisy neighbour on shared B-series (CPU credits exhausted!).
   - **Load balancer / ingress**: SNAT port exhaustion on egress, keep-alive/connection limits, TLS handshakes.
5. **Application internals.** Worker/thread pool saturation (requests queue → latency, CPU idle), GC pauses, retries
   with back-off amplifying a slow dependency, a new hot key or a much larger payload (data-shape change).

**Ranked hypotheses**: (1) DB contention / connection-pool exhaustion → (2) slow downstream API or queue backlog →
(3) DNS resolution latency → (4) CFS throttling or burstable-VM credit exhaustion → (5) SNAT/conntrack exhaustion →
(6) data-shape change.

**Immediate mitigation** (restore service, then find root cause): scale out manually (`kubectl scale --replicas=N`,
HPA will not fire at 35 % CPU); restart pods if a connection/thread leak is suspected; kill long-running DB
transactions / fail over to replica; raise or remove the CPU limit if throttled; enable rate limiting / circuit breaker
at the ingress to protect the dependency; roll back the last **configuration** change even though there was no deploy.

**Follow-up**: blameless post-mortem; alerts on p95/p99 and error budget, not CPU; distributed tracing (OpenTelemetry)
so the slow hop is visible in seconds; connection-pool sizing (PgBouncer); load test to find the knee; runbook for
this exact symptom; HPA on request rate/latency (KEDA) instead of CPU.

## 7. Production architecture (30 services, PostgreSQL/Redis/RabbitMQ, 500 rps, 99.9 %, PII)

Diagram and full decision table in [docs/architecture.md §2](docs/architecture.md#2-target-architecture-30-microservices-3-environments-999-).
Headline decisions: cluster + subscription per environment; single region with three AZs (99.9 % ≈ 43 min/month does
not justify multi-region); Argo CD GitOps with a namespace per team; managed PostgreSQL Flexible Server (zone-redundant
HA, PITR) and Redis Premium; RabbitMQ operator with quorum queues (Service Bus as the low-ops alternative); private
API server and private endpoints everywhere; Workload Identity + Key Vault CSI per service; Front Door + WAF; Managed
Prometheus/Grafana + OpenTelemetry; CMK encryption, audit logging and Azure Policy for the sensitive data.

## 8. Assumptions and trade-offs

| Chosen | Instead of | Because |
|---|---|---|
| **Cluster per environment** (`aks-webapp-dev` / `aks-webapp-prod`), each with its own resource group and state file — but **only `dev` was actually applied** | Applying both environments | Cluster-per-environment is the design (see `infra/modules/platform/main.tf`, and `deploy.yml` which targets `aks-webapp-<env>`); a second cluster would roughly double the ~$1/day, so prod stays defined-but-not-applied. `helm template -f values-prod.yaml` runs in CI on every commit, so the prod path is verified to render even though it is never deployed. Bringing prod up is one `terraform apply` |
| 1× B2als_v2 node, no AZs, Free tier | 3 AZ, Standard tier | ~$1/day vs ~$10/day; prod tfvars flips it. Burstable VM credit exhaustion is a known dev-only risk |
| Single region `israelcentral` for everything (state, identities' scope, workloads) | `northeurope` (first attempt) | Free subscriptions whitelist VM SKUs per region; B2s was rejected in northeurope (`az vm list-skus` shows `NotAvailableForSubscription`). israelcentral allows B2als_v2/D2s_v5, is closest to the team, and keeping state + workloads in one region simplifies data-residency and cost reporting |
| GHCR public image | ACR + private endpoint | Free; deploy identity needs no pull secret. Prod uses ACR with Defender scanning |
| Managed NGINX add-on, HTTP only | cert-manager + TLS | No DNS name in the assignment; add-on supports Key Vault certs once a hostname exists |
| Resource groups created by bootstrap | Terraform-created RGs | Lets the CI identity be **RG-scoped** instead of subscription Contributor |
| `AKS RBAC Cluster Admin` for the deploy identity | Namespace-scoped `RBAC Writer` | The deploy job creates and labels the namespace itself (`deploy.yml`), which needs cluster-scoped rights. Moving namespace creation + PSA labels into Terraform would let this drop to `RBAC Writer` on one namespace — the single biggest privilege reduction still available here |
| GitHub Actions | Jenkins | Nothing to host, native OIDC, environments with approvals; Jenkins would add a server to secure |

## 9. What I would do with more time

1. Actually apply the prod environment (already defined in `infra/envs/prod`, rendered by CI, never deployed) — ideally in its own subscription; private API server; NetworkPolicy default-deny.
2. TLS via the add-on's Key Vault integration or cert-manager; real DNS zone managed by Terraform.
3. Key Vault + Secrets Store CSI with per-service Workload Identity; External Secrets for GitOps.
4. Managed Prometheus + Grafana, SLO alerts, OpenTelemetry tracing; synthetic checks from outside Azure.
5. Supply chain: cosign signatures + Kyverno/Azure Policy admission, deploy by digest, SBOM, Dependabot.
6. Argo CD for deployments (pull-based, drift detection) once service count grows.
7. Chart tests (`helm unittest`), `tflint`/`checkov`/`trivy config` in CI, Terraform module versioning.
8. Cost: budgets/alerts, node auto-provisioning, spot pool for non-critical work.

## 10. AI tools

Claude Code was used as a pair programmer: drafting Terraform/Helm/workflow boilerplate and this document from an
agreed plan, and running lint/validate loops. All design decisions, trade-offs and the troubleshooting reasoning were
reviewed and are mine; every file was validated (`terraform validate`, `helm lint`, `pytest`, real pipeline runs).

## 11. Time log

Hands-on time is close to the 3-hour budget; wall-clock was longer because of waiting on Azure operations and the
two issues below, which are documented as learnings rather than hidden.

| Block | Hands-on |
|---|---|
| Plan, WSL tooling, app + Dockerfile + tests | ~30 min |
| Terraform modules/envs + bootstrap script | ~35 min |
| Helm chart | ~20 min |
| GitHub Actions workflows | ~25 min |
| Azure bootstrap, OIDC, first apply + deploy | ~40 min |
| Documentation (README, architecture, teardown) | ~30 min |

**Things that bit, and what was learned**
- GitHub's OIDC `sub` claim now embeds owner/repo IDs (`repo:owner@id/repo@id:...`); federated credentials with the classic subject fail with `AADSTS700213`. The bootstrap reads the IDs from the GitHub API.
- Free subscriptions whitelist VM SKUs per region: `Standard_B2s` is `NotAvailableForSubscription` in northeurope. `az vm list-skus` before choosing a region; everything was moved to a single region (israelcentral).
- Deleting and recreating a storage account with the same name within minutes leaves Azure Storage's authorization cache stale — data-plane RBAC returned 403 for over an hour. The state account name is now derived from subscription **and** region so a move never reuses a name.
- Trivy's SARIF mode ignores the severity filter; the HIGH/CRITICAL gate must be the table-format step, SARIF is report-only.
