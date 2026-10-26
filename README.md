# monitoring-via-gitops

RKE2 (CIS profile) on AWS plus a GitOps-managed, multi-tenant monitoring stack deployed by ArgoCD.

| Layer | What |
|---|---|
| Cluster | RKE2 `v1.37.1+rke2r1`, `profile: cis`, Calico, 3 control-plane (`c7i-flex.large`, 4 GiB) + 3 worker (`m7i-flex.large`, 8 GiB) nodes, Ubuntu 24.04, `us-east-1a` |
| Control-plane endpoint | AWS NLB (6443/9345). kube-vip is deployed as a static pod but its ARP VIP is not reachable inside a VPC |
| Cloud integration | aws-cloud-controller-manager (Service type `LoadBalancer` creates an NLB) |
| GitOps | ArgoCD installed on the new cluster, app-of-apps from `apps/` |
| Platform | cert-manager (self-signed CA), Longhorn, Istio (gateway), kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki, Alloy |
| Tenancy | One shared Grafana org; tenants are read-only Viewers who only see their own folder (dashboards with the namespace baked in); Loki tenant = namespace; reconciler CronJob |
| Demo tenants | `tenant-a`, `tenant-b` |

## Layout

```
infra/terraform/     AWS: VPC, EC2, IAM, NLB, cloud-init for RKE2 (CIS), ArgoCD and cloud controller manager
scripts/             SSH key generation, post-install bootstrap (kubeconfig, ArgoCD repo secret, root app)
bootstrap/           root ArgoCD Application (app-of-apps)
apps/                ArgoCD Applications for the platform, ordered with sync waves
appsets/             ApplicationSets that onboard one tenant per tenants/<name> directory
platform/            values and manifests for platform components
charts/              tenant, demo-app and reconciler Helm charts
tenants/             one directory per tenant (values.yaml)
```

## Deploy

Prerequisites: `terraform`, `aws` (logged in, region `us-east-1`), `kubectl`, `jq`, `ssh`.
The GitHub token that ArgoCD uses to read this private repo is expected at `../token-monitoring-via-gitops` (outside the repo; override with `TOKEN_FILE`).

```bash
./scripts/gen-ssh-keys.sh            # creates ~/.ssh/monitoring-poc-ed25519 only if absent
cd infra/terraform
terraform init
terraform apply                      # review the plan first
cd ../..
./scripts/post-install.sh            # kubeconfig, ArgoCD repo secret, root app
```

The security groups are open to `0.0.0.0/0` by default (`allowed_cidr`). Narrow it with `-var allowed_cidr=<your-ip>/32`.

The repo URL (`https://github.com/shahgnp/monitoring-via-gitops.git`, branch `main`) is hard-coded in `bootstrap/`, `apps/` and `appsets/`; replace it everywhere if you fork:

```bash
grep -rl 'shahgnp/monitoring-via-gitops' . | xargs sed -i 's#shahgnp/monitoring-via-gitops#<owner>/<repo>#g'
```

## Access

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl -n argocd port-forward svc/argocd-server 8080:443     # https://localhost:8080, user admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Grafana is exposed through the Istio gateway (NLB). Map the name to the NLB address:
LB=$(kubectl -n istio-ingress get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
dig +short "$LB"                                               # add one of the IPs to /etc/hosts:
# <ip>  grafana.poc.local
```

Open `https://grafana.poc.local` (accept the self-signed certificate warning).

| User | Password | Org role | Sees |
|---|---|---|---|
| `admin` | `Adm1n-Poc-2026` | Admin | everything: all-tenants dashboard, `Platform (admins only)` folder, Explore |
| `tenant-a` | `TenantA-Poc-2026` | Viewer | only the `tenant-a` folder |
| `tenant-a-viewer2` | `TenantA-Viewer2-2026` | Viewer | only the `tenant-a` folder |
| `tenant-b` | `TenantB-Poc-2026` | Viewer | only the `tenant-b` folder |

These are plaintext PoC credentials (no secret management). Change them in `platform/monitoring/kps-values.yaml` and `tenants/*/values.yaml`.

## What a tenant gets

Read-only access to the dashboards in the tenant's folder. The namespace is written into every query, so the URL and filters cannot switch to another tenant. The home page is the tenant's own overview. Explore is not available to Viewers, and dashboards cannot be edited.

| Dashboard | Content | Filters |
|---|---|---|
| Overview - metrics | running pods, restarts, CPU, memory, network, HTTP request rate | time range, pod |
| Logs and golden signals | traffic, errors, latency and saturation from the JSON access log, plus a searchable log view | time range, application, pod, container, HTTP status class, keyword/regex |

`SRE - all tenants (admins only) / Golden signals (logs) - all tenants` is the admin home page and shows every namespace. The Loki data sent to a tenant's dashboards goes through a datasource that only sends that tenant's Loki header.

Other applications need a JSON access log with `status` and `request_time` to light up the HTTP panels (the demo nginx logs are an example).

## How privileges work

All accounts live in one shared Grafana org (`Monitoring`).

- Tenant members are always read-only `Viewer`s, one team and one folder per tenant. Only the team can open its folder. The `SRE - all tenants` folder and the built-in `Platform (admins only)` folder have no team access, so only org admins see them.
- Members are defined in `tenants/<name>/values.yaml` (`members:` list: login, password, optional email) and created by the `grafana-reconciler` CronJob (every 2 minutes). Removing a member from Git deletes the account (admins are never deleted). Do not give tenant members Editor or Admin: Editors can use Explore and edit queries; the reconciler forces tenants to Viewer.
- Alerting: each tenant gets an `AlertmanagerConfig`; the operator adds a namespace matcher. The Grafana alerting UI is turned off so Viewers cannot browse other namespaces' alerts.

**Limitation:** isolation is by dashboards only. Viewers cannot use Explore or edit queries, but Grafana OSS cannot restrict datasource access per user: a tenant who calls Grafana's query API directly with their own login can query the shared Prometheus and Loki datasources for any namespace. If you need hard isolation, put an identity-aware gateway in front of Loki and Prometheus, or use one org per tenant.

### Add a tenant or a member

Create `tenants/<name>/values.yaml` (copy `tenants/tenant-a/values.yaml`; the directory name must equal the namespace) and push. The ApplicationSets create the namespace, alerting, the Grafana team, folder, members, dashboards and the demo workload. To add a login to an existing tenant, append to its `members:` list.
Removing a tenant directory removes its Kubernetes resources, but its Grafana team, folder and dashboards are not deleted automatically.

## Verify

```bash
kubectl get nodes                                                        # 6 Ready, v1.37.1+rke2r1
kubectl -n argocd get applications                                       # all Synced / Healthy
kubectl -n monitoring get pods
kubectl -n monitoring create job --from=cronjob/grafana-reconciler reconcile-now   # run the reconciler immediately
kubectl -n monitoring logs job/reconcile-now
```

In Grafana: log in as `tenant-a`; the home page is the `tenant-a` overview, the folder also holds the logs dashboard, and no other folder is visible. Changing filters or the URL cannot reach another namespace's data in the dashboards. `tenant-a` cannot edit, and has no Explore.

Prometheus targets (admin): kubelet, apiserver, etcd, kube-controller-manager, kube-scheduler, kube-proxy, coredns, Longhorn, Istio, demo apps.

## CIS notes

- Host prerequisites (etcd user, sysctl file) are applied by cloud-init before RKE2 starts.
- RKE2 enforces Pod Security `restricted` everywhere except `kube-system`. `monitoring` (node-exporter) and `longhorn-system` are labeled `privileged`; `istio-*` are `baseline`; `argocd` is `baseline`.
- Default service accounts in the namespaces created here have `automountServiceAccountToken: false`.
- Control-plane nodes are tainted `CriticalAddonsOnly` so workloads land on workers.
- Not covered: the `argocd` namespace default service account and NetworkPolicies, and audit-policy tuning.

## Teardown

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl -n argocd delete application root          # removes the apps, including the gateway NLB
kubectl -n istio-ingress get svc                   # wait until the LoadBalancer service is gone
cd infra/terraform && terraform destroy
```

Revoke the GitHub token and delete the generated SSH key if they are no longer needed.
