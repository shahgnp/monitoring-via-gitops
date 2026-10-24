#!/usr/bin/env bash
# Post-install: fetch kubeconfig, register the Git repo in ArgoCD with the token file, apply the root app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/monitoring-poc-ed25519}"
TOKEN_FILE="${TOKEN_FILE:-$REPO_ROOT/../token-monitoring-via-gitops}"
REPO_URL="${REPO_URL:-https://github.com/shahgnp/monitoring-via-gitops.git}"
GIT_USER="${GIT_USER:-shahgnp}"
EXPECTED_NODES="${EXPECTED_NODES:-6}"
KUBECONFIG_OUT="$REPO_ROOT/kubeconfig"

[[ -r "$TOKEN_FILE" ]] || { echo "Token file not found: $TOKEN_FILE" >&2; exit 1; }

NLB_DNS="$(terraform -chdir="$TF_DIR" output -raw api_nlb_dns)"
CP_IP="$(terraform -chdir="$TF_DIR" output -json control_plane_public_ips | jq -r '.[0]')"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

echo "Waiting for the first control-plane node ($CP_IP) to publish its kubeconfig..."
for _ in $(seq 1 90); do
  if ssh "${SSH_OPTS[@]}" "ubuntu@$CP_IP" 'sudo test -s /etc/rancher/rke2/rke2.yaml' 2>/dev/null; then
    break
  fi
  sleep 10
done

ssh "${SSH_OPTS[@]}" "ubuntu@$CP_IP" 'sudo cat /etc/rancher/rke2/rke2.yaml' \
  | sed "s#https://127.0.0.1:6443#https://${NLB_DNS}:6443#" > "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"
export KUBECONFIG="$KUBECONFIG_OUT"

echo "Waiting for $EXPECTED_NODES Ready nodes..."
for _ in $(seq 1 90); do
  ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)"
  [[ "$ready" -ge "$EXPECTED_NODES" ]] && break
  sleep 10
done
kubectl get nodes -o wide

echo "Waiting for ArgoCD..."
for _ in $(seq 1 90); do
  kubectl get crd applications.argoproj.io >/dev/null 2>&1 && break
  sleep 10
done
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

echo "Registering the Git repository in ArgoCD (token is read from $TOKEN_FILE and not printed)..."
kubectl -n argocd create secret generic repo-monitoring-via-gitops \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$GIT_USER" \
  --from-file=password=<(tr -d '\r\n' < "$TOKEN_FILE") \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f -

kubectl apply -f "$REPO_ROOT/bootstrap/root-app.yaml"

cat <<EOF

Done.
  export KUBECONFIG=$KUBECONFIG_OUT
  ArgoCD UI:  kubectl -n argocd port-forward svc/argocd-server 8080:443   (https://localhost:8080)
  ArgoCD admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF
