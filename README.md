# monitoring-via-gitops

RKE2 (CIS profile) on AWS plus a GitOps-managed, multi-tenant monitoring stack deployed by ArgoCD.

| Layer | What |
|---|---|
| Cluster | RKE2 `v1.37.1+rke2r1`, `profile: cis`, Calico, 3 control-plane (`c7i-flex.large`, 4 GiB) + 3 worker (`m7i-flex.large`, 8 GiB) nodes, Ubuntu 24.04, `us-east-1a` |
| Control-plane endpoint | AWS NLB (6443/9345). kube-vip is deployed as a static pod but its ARP VIP is not reachable inside a VPC |
| Cloud integration | aws-cloud-controller-manager (Service type `LoadBalancer` creates an NLB) |
| GitOps | ArgoCD installed on the new cluster, app-of-apps from `apps/` |
| Platform | cert-manager (self-signed CA), Longhorn, Istio (gateway), kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki, Alloy |
| Tenancy | One shared Grafana org; members with Viewer/Editor/Admin roles, a team and a folder per tenant, Loki tenant = namespace, reconciler CronJob |
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
| `admin` | `Adm1n-Poc-2026` | Admin | everything, including the `Platform (admins only)` folder |
| `tenant-a` | `TenantA-Poc-2026` | Viewer | `SRE - all tenants` and the `tenant-a` folder |
| `tenant-a-editor` | `TenantA-Editor-2026` | Editor | same, and can edit the `tenant-a` folder |
| `tenant-b` | `TenantB-Poc-2026` | Viewer | `SRE - all tenants` and the `tenant-b` folder |
| `tenant-b-editor` | `TenantB-Editor-2026` | Editor | same, and can edit the `tenant-b` folder |

These are plaintext PoC credentials (no secret management). Change them in `platform/monitoring/kps-values.yaml` and `tenants/*/values.yaml`.

## Dashboards: the four golden signals from logs

`SRE - all tenants / Golden signals (logs) - all tenants` is the home dashboard. It uses the `Loki (all namespaces)` datasource with a tenant (namespace) and application selector, and is built from the demo nginx JSON access log (`status`, `request_time`):

| Signal | Panels |
|---|---|
| Traffic | requests/s by tenant and by status class |
| Errors | 5xx/s, error ratio, availability against a 99.5% SLO, recent 5xx lines |
| Latency | p50/p95/p99 and average by tenant, slow requests (> 1s) |
| Saturation | 429/503 responses, share of slow requests, log throughput, resource-pressure messages |

Every tenant also gets the same dashboard pre-filtered to its namespace in its own folder. The dashboard is a Grafana JSON document (`charts/reconciler/files/golden-signals-logs.json`; Grafana has no XML dashboard format) and is imported by the reconciler. Other applications need a JSON access log with `status` and `request_time` to light up the HTTP panels.

## How privileges work

All accounts live in one shared Grafana org (`Monitoring`). Privileges are controlled with member accounts:

- Org role per member: `Viewer`, `Editor` or `Admin`.
- One team and one folder per tenant. The team can view the folder; members with the `Editor` role can also edit it. The `SRE - all tenants` folder is visible to every member, and the built-in infrastructure dashboards are in `Platform (admins only)`.
- Members are defined in `tenants/<name>/values.yaml` (`members:` list) and created by the `grafana-reconciler` CronJob (every 2 minutes). Accounts created by hand in the Grafana UI (Administration > Users) are left alone, so an admin can also add members there.
- Alerting: each tenant gets an `AlertmanagerConfig`; the operator adds a namespace matcher so routes only match that tenant's alerts.

**Limitation:** Grafana OSS cannot restrict datasource access per user. In the shared org every member can query the shared Loki and Prometheus datasources (for example in Explore), so folders and roles limit dashboards and edit rights, not data. Hard per-tenant data isolation needs one org per tenant (the previous design) or an identity-aware proxy.

### Add a tenant or a member

Create `tenants/<name>/values.yaml` (copy `tenants/tenant-a/values.yaml`; the directory name must equal the namespace) and push. The ApplicationSets create the namespace, alerting, the Grafana team, folder, members and the demo workload. To add a member to an existing tenant, append to its `members:` list.
Removing a tenant or member from Git does not delete the Grafana team, folder or user.

## Verify

```bash
kubectl get nodes                                                        # 6 Ready, v1.37.1+rke2r1
kubectl -n argocd get applications                                       # all Synced / Healthy
kubectl -n monitoring get pods
kubectl -n monitoring create job --from=cronjob/grafana-reconciler reconcile-now   # run the reconciler immediately
kubectl -n monitoring logs job/reconcile-now
```

In Grafana: log in as `tenant-a`; the home dashboard shows the golden signals for all tenants and the `tenant-a` folder holds the same dashboard filtered to `tenant-a`. `tenant-a` cannot see the `tenant-b` folder or `Platform (admins only)`; `tenant-a-editor` can edit the `tenant-a` folder but `tenant-a` (Viewer) cannot.

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
