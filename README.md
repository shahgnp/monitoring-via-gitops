# monitoring-via-gitops

RKE2 (CIS profile) on AWS plus a GitOps-managed, multi-tenant monitoring stack deployed by ArgoCD.

| Layer | What |
|---|---|
| Cluster | RKE2 `v1.37.1+rke2r1`, `profile: cis`, Calico, 3 control-plane + 3 worker nodes (Ubuntu 24.04, `us-east-1a`) |
| Control-plane endpoint | AWS NLB (6443/9345). kube-vip is deployed as a static pod but its ARP VIP is not reachable inside a VPC |
| Cloud integration | aws-cloud-controller-manager (Service type `LoadBalancer` creates an NLB) |
| GitOps | ArgoCD installed on the new cluster, app-of-apps from `apps/` |
| Platform | cert-manager (self-signed CA), Longhorn, Istio (gateway), kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki, Alloy |
| Tenancy | Grafana org per tenant, `prom-label-proxy` per tenant, Loki tenant = namespace, reconciler CronJob |
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

| User | Password | Sees |
|---|---|---|
| `admin` | `Adm1n-Poc-2026` | everything (org 1: all Prometheus data, `Loki (all namespaces)`) |
| `tenant-a` | `TenantA-Poc-2026` | only namespace `tenant-a` |
| `tenant-b` | `TenantB-Poc-2026` | only namespace `tenant-b` |

These are plaintext PoC credentials (no secret management). Change them in `platform/monitoring/kps-values.yaml` and `tenants/*/values.yaml`.

## How tenancy works

- Metrics: each tenant's Grafana datasource points at its own `prom-label-proxy`, which forces `namespace=<tenant namespace>` on every query. Prometheus, Alertmanager and Loki are only reachable from the `monitoring` namespace (NetworkPolicies in `platform/monitoring-extras`).
- Logs: Alloy sets the Loki tenant to the pod's namespace. A tenant's Grafana datasource sends `X-Scope-OrgID=<namespace>`; tenant users cannot edit datasources (Viewer role).
- Grafana: the `grafana-reconciler` CronJob (every 2 minutes) creates the org, the Viewer-only user and datasources from the `tenant-*` Secrets in `monitoring`, imports the tenant dashboard, and keeps the admin `Loki (all namespaces)` datasource current.
- Alerting: each tenant gets an `AlertmanagerConfig`; the operator adds a namespace matcher so routes only match that tenant's alerts.

### Add a tenant

Create `tenants/<name>/values.yaml` (copy `tenants/tenant-a/values.yaml`; the directory name must equal the namespace) and push. The ApplicationSets create the namespace, proxy, alerting, Grafana org/user and the demo workload.
Removing a tenant directory removes its Kubernetes resources, but the Grafana org and user are not deleted automatically.

## Verify

```bash
kubectl get nodes                                                        # 6 Ready, v1.37.1+rke2r1
kubectl -n argocd get applications                                       # all Synced / Healthy
kubectl -n monitoring get pods
kubectl -n monitoring create job --from=cronjob/grafana-reconciler reconcile-now   # run the reconciler immediately
kubectl -n monitoring logs job/reconcile-now
```

In Grafana: as `tenant-a`, the home dashboard shows `tenant-a` metrics and logs only; querying `{namespace="tenant-b"}` or `up{namespace="tenant-b"}` returns nothing. As `admin`, Explore with `Loki (all namespaces)` shows all namespaces.

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
