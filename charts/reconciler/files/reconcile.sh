#!/usr/bin/env bash
# Idempotently reconciles Grafana with the tenant registry Secrets (label monitoring.poc/tenant=true).
set -uo pipefail

GRAFANA_URL="${GRAFANA_URL:?}"
LOKI_URL="${LOKI_URL:?}"
GF_USER="${GF_USER:?}"
GF_PASS="${GF_PASS:?}"
NS="${POD_NAMESPACE:-monitoring}"
TMP=/tmp/reconcile
mkdir -p "$TMP"

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

# gf METHOD PATH [JSON]; ORG selects the organisation (default 1). Sets CODE and OUT.
gf() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -o "$TMP/resp" -w '%{http_code}' -X "$method" -u "$GF_USER:$GF_PASS"
    -H 'Content-Type: application/json' -H "X-Grafana-Org-Id: ${ORG:-1}")
  [[ -n "$data" ]] && args+=(--data "$data")
  CODE=$(curl "${args[@]}" "$GRAFANA_URL$path") || CODE=000
  OUT=$(cat "$TMP/resp" 2>/dev/null || true)
}

wait_for_grafana() {
  for _ in $(seq 1 30); do
    curl -fsS "$GRAFANA_URL/api/health" >/dev/null 2>&1 && return 0
    sleep 5
  done
  log "Grafana is not reachable"
  return 1
}

ensure_org() {
  local name=$1
  ORG=1 gf GET "/api/orgs/name/$(jq -rn --arg n "$name" '$n|@uri')"
  if [[ $CODE == 200 ]]; then jq -r .id <<<"$OUT"; return 0; fi
  ORG=1 gf POST /api/orgs "$(jq -n --arg n "$name" '{name:$n}')"
  [[ $CODE == 200 ]] || { log "org $name: create failed ($CODE) $OUT"; return 1; }
  jq -r .orgId <<<"$OUT"
}

ensure_user() {
  local login=$1 email=$2 pass=$3 org=$4 uid
  ORG=1 gf GET "/api/users/lookup?loginOrEmail=$(jq -rn --arg n "$login" '$n|@uri')"
  if [[ $CODE == 200 ]]; then
    uid=$(jq -r .id <<<"$OUT")
    # Keep the password in sync with Git.
    if [[ $(curl -s -o /dev/null -w '%{http_code}' -u "$login:$pass" "$GRAFANA_URL/api/user") != 200 ]]; then
      ORG=1 gf PUT "/api/admin/users/$uid/password" "$(jq -n --arg p "$pass" '{password:$p}')"
      [[ $CODE == 200 ]] || log "user $login: password update failed ($CODE) $OUT"
    fi
  else
    ORG=1 gf POST /api/admin/users "$(jq -n --arg n "$login" --arg e "$email" --arg l "$login" --arg p "$pass" --argjson o "$org" \
      '{name:$n,email:$e,login:$l,password:$p,orgId:$o}')"
    [[ $CODE == 200 ]] || { log "user $login: create failed ($CODE) $OUT"; return 1; }
    uid=$(jq -r .id <<<"$OUT")
  fi
  echo "$uid"
}

# The user must be a Viewer in the tenant org and in no other org.
# Grafana creates a personal org (named after the email) with Admin rights for every new user; delete it.
ensure_membership() {
  local uid=$1 org=$2 login=$3 email=$4 orgs current other name
  ORG=1 gf GET "/api/users/$uid/orgs"
  orgs=$OUT
  current=$(jq -r --argjson o "$org" '.[] | select(.orgId==$o) | .role' <<<"$orgs")
  if [[ -z "$current" ]]; then
    ORG=1 gf POST "/api/orgs/$org/users" "$(jq -n --arg l "$login" '{loginOrEmail:$l,role:"Viewer"}')"
    [[ $CODE == 200 ]] || log "user $login: add to org $org failed ($CODE) $OUT"
  elif [[ "$current" != "Viewer" ]]; then
    ORG=1 gf PATCH "/api/orgs/$org/users/$uid" '{"role":"Viewer"}'
  fi
  while IFS=$'\t' read -r other name; do
    [[ -n "$other" ]] || continue
    if [[ "$other" != 1 && ( "$name" == "$email" || "$name" == "$login" ) ]]; then
      ORG=1 gf DELETE "/api/orgs/$other"
    else
      ORG=1 gf DELETE "/api/orgs/$other/users/$uid"
    fi
  done < <(jq -r --argjson o "$org" '.[] | select(.orgId!=$o) | "\(.orgId)\t\(.name)"' <<<"$orgs")
}

upsert_datasource() {
  local org=$1 uid=$2 body=$3
  ORG=$org gf GET "/api/datasources/uid/$uid"
  if [[ $CODE == 200 ]]; then
    ORG=$org gf PUT "/api/datasources/uid/$uid" "$body"
  else
    ORG=$org gf POST /api/datasources "$body"
  fi
  [[ $CODE == 200 ]] || log "datasource $uid (org $org) failed ($CODE) $OUT"
}

import_dashboard() {
  local org=$1 tenant=$2 dash
  dash=$(sed -e "s/__PROM_UID__/prom-$tenant/g" -e "s/__LOKI_UID__/loki-$tenant/g" /dashboards/tenant-overview.json)
  ORG=$org gf POST /api/dashboards/db "$(jq -n --argjson d "$dash" '{dashboard:$d,overwrite:true,message:"reconciler"}')"
  [[ $CODE == 200 ]] || { log "dashboard import (org $org) failed ($CODE) $OUT"; return 0; }
  ORG=$org gf PUT /api/org/preferences '{"homeDashboardUID":"tenant-overview"}'
}

reconcile_tenant() {
  local tenant=$1 namespace=$2 login=$3 email=$4 pass=$5 prom_url=$6 org uid
  log "tenant $tenant (namespace $namespace)"
  org=$(ensure_org "$tenant") || return 1
  uid=$(ensure_user "$login" "$email" "$pass" "$org") || return 1
  ensure_membership "$uid" "$org" "$login" "$email"

  upsert_datasource "$org" "prom-$tenant" "$(jq -n --arg u "$prom_url" --arg id "prom-$tenant" \
    '{name:"Prometheus",uid:$id,type:"prometheus",access:"proxy",url:$u,isDefault:true,jsonData:{timeInterval:"30s"}}')"
  upsert_datasource "$org" "loki-$tenant" "$(jq -n --arg u "$LOKI_URL" --arg id "loki-$tenant" --arg ns "$namespace" \
    '{name:"Loki",uid:$id,type:"loki",access:"proxy",url:$u,jsonData:{httpHeaderName1:"X-Scope-OrgID"},secureJsonData:{httpHeaderValue1:$ns}}')"
  import_dashboard "$org" "$tenant"
}

# The admin sees logs of every namespace through Loki's multi-tenant query syntax.
reconcile_admin() {
  local all
  all=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | paste -sd'|' -)
  [[ -n "$all" ]] || { log "no namespaces found"; return 1; }
  upsert_datasource 1 loki-all "$(jq -n --arg u "$LOKI_URL" --arg v "$all" \
    '{name:"Loki (all namespaces)",uid:"loki-all",type:"loki",access:"proxy",url:$u,jsonData:{httpHeaderName1:"X-Scope-OrgID"},secureJsonData:{httpHeaderValue1:$v}}')"
}

main() {
  local failed=0 row
  wait_for_grafana || exit 1
  reconcile_admin || failed=1

  while read -r row; do
    [[ -n "$row" ]] || continue
    reconcile_tenant \
      "$(jq -r .tenant <<<"$row")" "$(jq -r .namespace <<<"$row")" "$(jq -r .login <<<"$row")" \
      "$(jq -r .email <<<"$row")" "$(jq -r .password <<<"$row")" "$(jq -r .prometheusUrl <<<"$row")" || failed=1
  done < <(kubectl -n "$NS" get secrets -l monitoring.poc/tenant=true -o json | jq -c '.items[] | .data | map_values(@base64d)')

  exit "$failed"
}

main
