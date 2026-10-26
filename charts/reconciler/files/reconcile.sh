#!/usr/bin/env bash
# Idempotently reconciles Grafana (single org) with the tenant registry Secrets (label monitoring.poc/tenant=true):
# members with org roles, one team and one folder per tenant, and the golden-signals dashboards.
set -uo pipefail

GRAFANA_URL="${GRAFANA_URL:?}"
LOKI_URL="${LOKI_URL:?}"
GF_USER="${GF_USER:?}"
GF_PASS="${GF_PASS:?}"
NS="${POD_NAMESPACE:-monitoring}"
DASHBOARD=/dashboards/golden-signals-logs.json
SRE_FOLDER=sre-all-tenants
TMP=/tmp/reconcile
mkdir -p "$TMP"

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

# gf METHOD PATH [JSON]; sets CODE and OUT. Everything happens in org 1.
gf() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -o "$TMP/resp" -w '%{http_code}' -X "$method" -u "$GF_USER:$GF_PASS"
    -H 'Content-Type: application/json' -H 'X-Grafana-Org-Id: 1')
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

upsert_datasource() {
  local uid=$1 body=$2
  gf GET "/api/datasources/uid/$uid"
  if [[ $CODE == 200 ]]; then
    gf PUT "/api/datasources/uid/$uid" "$body"
  else
    gf POST /api/datasources "$body"
  fi
  [[ $CODE == 200 ]] || log "datasource $uid failed ($CODE) $OUT"
}

ensure_folder() {
  local uid=$1 title=$2
  gf GET "/api/folders/$uid"
  [[ $CODE == 200 ]] && return 0
  gf POST /api/folders "$(jq -n --arg u "$uid" --arg t "$title" '{uid:$u,title:$t}')"
  [[ $CODE == 200 ]] || { log "folder $uid: create failed ($CODE) $OUT"; return 1; }
}

# Replaces the folder's custom permissions; org admins always keep full access.
set_folder_permissions() {
  local uid=$1 items=$2
  gf POST "/api/folders/$uid/permissions" "$(jq -n --argjson i "$items" '{items:$i}')"
  [[ $CODE == 200 ]] || log "folder $uid: permissions failed ($CODE) $OUT"
}

import_dashboard() {
  local folder=$1 dash=$2
  gf POST /api/dashboards/db "$(jq -n --argjson d "$dash" --arg f "$folder" '{dashboard:$d,folderUid:$f,overwrite:true,message:"reconciler"}')"
  [[ $CODE == 200 ]] || log "dashboard import into $folder failed ($CODE) $OUT"
}

ensure_team() {
  local name=$1
  gf GET "/api/teams/search?name=$(jq -rn --arg n "$name" '$n|@uri')"
  if [[ $CODE == 200 ]]; then
    local id
    id=$(jq -r --arg n "$name" '.teams[] | select(.name==$n) | .id' <<<"$OUT" | head -n1)
    [[ -n "$id" ]] && { echo "$id"; return 0; }
  fi
  gf POST /api/teams "$(jq -n --arg n "$name" '{name:$n}')"
  [[ $CODE == 200 ]] || { log "team $name: create failed ($CODE) $OUT"; return 1; }
  jq -r .teamId <<<"$OUT"
}

ensure_team_member() {
  local team=$1 uid=$2
  gf GET "/api/teams/$team/members"
  if jq -e --argjson u "$uid" 'any(.[]; .userId==$u)' <<<"$OUT" >/dev/null 2>&1; then return 0; fi
  gf POST "/api/teams/$team/members" "$(jq -n --argjson u "$uid" '{userId:$u}')"
  [[ $CODE == 200 ]] || log "team $team: add member $uid failed ($CODE) $OUT"
}

ensure_user() {
  local login=$1 email=$2 pass=$3 uid
  gf GET "/api/users/lookup?loginOrEmail=$(jq -rn --arg n "$login" '$n|@uri')"
  if [[ $CODE == 200 ]]; then
    uid=$(jq -r .id <<<"$OUT")
    # Keep the password in sync with Git.
    if [[ $(curl -s -o /dev/null -w '%{http_code}' -u "$login:$pass" "$GRAFANA_URL/api/user") != 200 ]]; then
      gf PUT "/api/admin/users/$uid/password" "$(jq -n --arg p "$pass" '{password:$p}')"
      [[ $CODE == 200 ]] || log "user $login: password update failed ($CODE) $OUT"
    fi
  else
    gf POST /api/admin/users "$(jq -n --arg n "$login" --arg e "$email" --arg l "$login" --arg p "$pass" \
      '{name:$n,email:$e,login:$l,password:$p}')"
    [[ $CODE == 200 ]] || { log "user $login: create failed ($CODE) $OUT"; return 1; }
    uid=$(jq -r .id <<<"$OUT")
  fi
  echo "$uid"
}

# Puts the user in org 1 with the requested role and makes it their current org.
ensure_org_role() {
  local uid=$1 login=$2 role=$3 current
  gf GET "/api/users/$uid/orgs"
  current=$(jq -r '.[] | select(.orgId==1) | .role' <<<"$OUT")
  if [[ -z "$current" ]]; then
    gf POST /api/orgs/1/users "$(jq -n --arg l "$login" --arg r "$role" '{loginOrEmail:$l,role:$r}')"
    [[ $CODE == 200 ]] || log "user $login: add to org failed ($CODE) $OUT"
  elif [[ "$current" != "$role" ]]; then
    gf PATCH "/api/orgs/1/users/$uid" "$(jq -n --arg r "$role" '{role:$r}')"
    [[ $CODE == 200 ]] || log "user $login: role change failed ($CODE) $OUT"
  fi
  gf POST "/api/users/$uid/using/1"
}

# Earlier versions used one org per tenant; drop it once members have moved to org 1.
drop_legacy_org() {
  local name=$1 id
  gf GET "/api/orgs/name/$(jq -rn --arg n "$name" '$n|@uri')"
  [[ $CODE == 200 ]] || return 0
  id=$(jq -r .id <<<"$OUT")
  [[ "$id" != 1 ]] || return 0
  gf DELETE "/api/orgs/$id"
  log "removed legacy org $name"
}

reconcile_shared() {
  upsert_datasource loki-all "$(jq -n --arg u "$LOKI_URL" --arg v "$1" \
    '{name:"Loki (all namespaces)",uid:"loki-all",type:"loki",access:"proxy",url:$u,jsonData:{httpHeaderName1:"X-Scope-OrgID"},secureJsonData:{httpHeaderValue1:$v}}')"

  ensure_folder "$SRE_FOLDER" "SRE - all tenants" || return 1
  set_folder_permissions "$SRE_FOLDER" '[{"role":"Viewer","permission":1},{"role":"Editor","permission":1}]'
  import_dashboard "$SRE_FOLDER" "$(cat "$DASHBOARD")"
  gf PUT /api/org/preferences '{"homeDashboardUID":"golden-signals-all"}'
}

reconcile_tenant() {
  local tenant=$1 namespace=$2 members=$3
  local team folder items row login email pass role uid dash
  log "tenant $tenant (namespace $namespace)"

  team=$(ensure_team "$tenant") || return 1
  folder="tenant-$tenant"
  ensure_folder "$folder" "$tenant" || return 1

  # Team members view the folder; individual Editors may edit it.
  items=$(jq -n --argjson t "$team" '[{teamId:$t,permission:1}]')

  while read -r row; do
    [[ -n "$row" ]] || continue
    login=$(jq -r .login <<<"$row")
    email=$(jq -r --arg d "$login@poc.local" '.email // $d' <<<"$row")
    pass=$(jq -r .password <<<"$row")
    role=$(jq -r '.role // "Viewer"' <<<"$row")
    case "$role" in Viewer|Editor|Admin) ;; *) log "member $login: invalid role $role"; continue ;; esac

    uid=$(ensure_user "$login" "$email" "$pass") || continue
    ensure_org_role "$uid" "$login" "$role"
    ensure_team_member "$team" "$uid"
    if [[ "$role" == "Editor" ]]; then
      items=$(jq --argjson u "$uid" '. + [{userId:$u,permission:2}]' <<<"$items")
    fi
  done < <(jq -c '.[]' <<<"$members")

  set_folder_permissions "$folder" "$items"

  dash=$(jq --arg t "$tenant" --arg ns "$namespace" '
      .uid = "golden-signals-" + $t
      | .title = $t + " - golden signals (logs)"
      | (.templating.list[] | select(.name=="namespace")).current = {text:[$ns],value:[$ns]}
      | (.templating.list[] | select(.name=="namespace")).includeAll = false' "$DASHBOARD")
  import_dashboard "$folder" "$dash"

  drop_legacy_org "$tenant"
}

main() {
  local failed=0 row all
  wait_for_grafana || exit 1

  # The admin sees logs of every namespace through Loki's multi-tenant query syntax.
  all=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | paste -sd'|' -)
  [[ -n "$all" ]] || { log "no namespaces found"; exit 1; }
  reconcile_shared "$all" || failed=1

  while read -r row; do
    [[ -n "$row" ]] || continue
    reconcile_tenant "$(jq -r .tenant <<<"$row")" "$(jq -r .namespace <<<"$row")" "$(jq -r .members <<<"$row")" || failed=1
  done < <(kubectl -n "$NS" get secrets -l monitoring.poc/tenant=true -o json | jq -c '.items[] | .data | map_values(@base64d)')

  exit "$failed"
}

main
