#!/usr/bin/env bash
# Idempotently reconciles Grafana (single org) with the tenant registry Secrets (label monitoring.poc/tenant=true).
# Tenants are read-only Viewers; they only see the folder of their team, whose dashboards have the namespace baked in.
set -uo pipefail

GRAFANA_URL="${GRAFANA_URL:?}"
LOKI_URL="${LOKI_URL:?}"
GF_USER="${GF_USER:?}"
GF_PASS="${GF_PASS:?}"
NS="${POD_NAMESPACE:-monitoring}"
DASH_DIR=/dashboards
SRE_FOLDER=sre-all-tenants
PLATFORM_FOLDER_TITLE="Platform (admins only)"
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

loki_datasource_body() {
  local uid=$1 name=$2 tenant_header=$3
  jq -n --arg u "$LOKI_URL" --arg id "$uid" --arg n "$name" --arg v "$tenant_header" \
    '{name:$n,uid:$id,type:"loki",access:"proxy",url:$u,jsonData:{httpHeaderName1:"X-Scope-OrgID"},secureJsonData:{httpHeaderValue1:$v}}'
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

# render_dashboard FILE UID TITLE NS_REGEX NS_LIST LOKI_UID: bakes the tenant's namespaces and datasources into a dashboard template.
# The namespace filter variable is hidden when the tenant has a single namespace.
render_dashboard() {
  local file=$1 uid=$2 title=$3 regex=$4 list=$5 loki=$6 hide=0
  [[ "$list" == *,* ]] || hide=2
  sed -e "s/__NAMESPACE__/$regex/g" -e "s/__NS_LIST__/$list/g" -e "s/__LOKI_UID__/$loki/g" -e "s/__PROM_UID__/prometheus/g" "$file" \
    | jq --arg u "$uid" --arg t "$title" --argjson h "$hide" \
        '.uid=$u | .title=$t | (.templating.list[] | select(.name=="nsfilter")).hide = $h'
}

ensure_team() {
  local name=$1 id
  gf GET "/api/teams/search?name=$(jq -rn --arg n "$name" '$n|@uri')"
  if [[ $CODE == 200 ]]; then
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

# Members that are no longer listed in Git lose their access: removed from the team and deleted unless they are admins.
prune_team_members() {
  local team=$1 keep=$2 admin_id=$3 uid login
  gf GET "/api/teams/$team/members"
  while IFS=$'\t' read -r uid login; do
    [[ -n "$uid" && "$uid" != "$admin_id" ]] || continue
    jq -e --argjson u "$uid" 'index($u)' <<<"$keep" >/dev/null 2>&1 && continue
    gf DELETE "/api/teams/$team/members/$uid"
    if jq -e --arg l "$login" 'index($l)' <<<"$ALL_LOGINS" >/dev/null 2>&1; then continue; fi
    gf GET "/api/users/$uid"
    if [[ "$(jq -r .isGrafanaAdmin <<<"$OUT")" == "true" ]]; then continue; fi
    gf GET "/api/users/$uid/orgs"
    if [[ "$(jq -r '[.[] | select(.orgId==1) | .role][0] // ""' <<<"$OUT")" == "Admin" ]]; then continue; fi
    gf DELETE "/api/admin/users/$uid"
    log "removed member $login (no longer in Git)"
  done < <(jq -r '.[] | "\(.userId)\t\(.login)"' <<<"$OUT")
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

# Tenant members are always read-only Viewers of org 1.
ensure_viewer() {
  local uid=$1 login=$2 current
  gf GET "/api/users/$uid/orgs"
  current=$(jq -r '.[] | select(.orgId==1) | .role' <<<"$OUT")
  if [[ -z "$current" ]]; then
    gf POST /api/orgs/1/users "$(jq -n --arg l "$login" '{loginOrEmail:$l,role:"Viewer"}')"
    [[ $CODE == 200 ]] || log "user $login: add to org failed ($CODE) $OUT"
  elif [[ "$current" != "Viewer" ]]; then
    gf PATCH "/api/orgs/1/users/$uid" '{"role":"Viewer"}'
    [[ $CODE == 200 ]] || log "user $login: role change failed ($CODE) $OUT"
  fi
  gf POST "/api/users/$uid/using/1"
}

# The kube-prometheus-stack dashboards are provisioned into this folder; empty permissions leave it to org admins.
restrict_platform_folder() {
  local uid
  gf GET /api/folders
  uid=$(jq -r --arg t "$PLATFORM_FOLDER_TITLE" '.[] | select(.title==$t) | .uid' <<<"$OUT" | head -n1)
  [[ -n "$uid" ]] || { log "platform folder not provisioned yet"; return 0; }
  set_folder_permissions "$uid" '[]'
}

reconcile_shared() {
  local all=$1
  upsert_datasource loki-all "$(loki_datasource_body loki-all "Loki (all namespaces)" "$all")"

  restrict_platform_folder
  gf PUT /api/orgs/1 '{"name":"Monitoring"}'

  # The all-tenants dashboard shows every namespace, so it is for admins only.
  ensure_folder "$SRE_FOLDER" "SRE - all tenants (admins only)" || return 1
  set_folder_permissions "$SRE_FOLDER" '[]'
  import_dashboard "$SRE_FOLDER" "$(cat "$DASH_DIR/golden-signals-logs.json")"
  gf PUT /api/org/preferences '{"homeDashboardUID":"golden-signals-all"}'
}

reconcile_tenant() {
  local tenant=$1 namespaces=$2 members=$3 admin_id=$4
  local team folder keep='[]' row login email pass role uid loki="loki-$tenant" regex list
  # Namespaces become a regex for queries and a multi-tenant Loki header (both use "|"), and a comma list for the filter.
  regex=$(jq -r 'join("|")' <<<"$namespaces")
  list=$(jq -r 'join(",")' <<<"$namespaces")
  log "tenant $tenant (namespaces $list)"

  team=$(ensure_team "$tenant") || return 1
  folder="tenant-$tenant"
  ensure_folder "$folder" "$tenant" || return 1
  # Grafana adds the creator to the team; admins use the org home page instead of a tenant home.
  gf DELETE "/api/teams/$team/members/$admin_id"

  # Logs go through a datasource that sends only this tenant's Loki header.
  upsert_datasource "$loki" "$(loki_datasource_body "$loki" "Loki ($tenant)" "$regex")"

  while read -r row; do
    [[ -n "$row" ]] || continue
    login=$(jq -r .login <<<"$row")
    email=$(jq -r --arg d "$login@poc.local" '.email // $d' <<<"$row")
    pass=$(jq -r .password <<<"$row")
    role=$(jq -r '.role // "Viewer"' <<<"$row")
    [[ "$role" == "Viewer" ]] || log "member $login: role $role is not allowed for tenants, using Viewer"

    uid=$(ensure_user "$login" "$email" "$pass") || continue
    ensure_viewer "$uid" "$login"
    ensure_team_member "$team" "$uid"
    keep=$(jq --argjson u "$uid" '. + [$u]' <<<"$keep")
  done < <(jq -c '.[]' <<<"$members")

  prune_team_members "$team" "$keep" "$admin_id"

  # Only the team (read-only) can open the tenant folder.
  set_folder_permissions "$folder" "$(jq -n --argjson t "$team" '[{teamId:$t,permission:1}]')"

  import_dashboard "$folder" "$(render_dashboard "$DASH_DIR/tenant-overview.json" "overview-$tenant" "Overview - metrics" "$regex" "$list" "$loki")"
  import_dashboard "$folder" "$(render_dashboard "$DASH_DIR/tenant-logs.json" "logs-$tenant" "Logs and golden signals" "$regex" "$list" "$loki")"
  gf PUT "/api/teams/$team/preferences" "$(jq -n --arg u "overview-$tenant" '{homeDashboardUID:$u}')"

  # Dashboards from the earlier shared-filter design.
  gf DELETE "/api/dashboards/uid/golden-signals-$tenant"
}

main() {
  local failed=0 row all admin_id
  wait_for_grafana || exit 1

  gf GET /api/user
  admin_id=$(jq -r .id <<<"$OUT")

  # The admin sees logs of every namespace through Loki's multi-tenant query syntax.
  all=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | paste -sd'|' -)
  [[ -n "$all" ]] || { log "no namespaces found"; exit 1; }
  reconcile_shared "$all" || failed=1

  # A login may belong to several tenants; it is only deleted when no tenant lists it any more.
  ALL_LOGINS=$(kubectl -n "$NS" get secrets -l monitoring.poc/tenant=true -o json \
    | jq -c '[.items[].data.members | @base64d | fromjson | .[].login] | unique')

  while read -r row; do
    [[ -n "$row" ]] || continue
    # `namespaces` is a JSON array stored as a string; older registry entries only have `namespace`.
    reconcile_tenant "$(jq -r .tenant <<<"$row")" \
      "$(jq -c 'if .namespaces then (.namespaces | fromjson) else [.namespace] end' <<<"$row")" \
      "$(jq -r .members <<<"$row")" "$admin_id" || failed=1
  done < <(kubectl -n "$NS" get secrets -l monitoring.poc/tenant=true -o json | jq -c '.items[] | .data | map_values(@base64d)')

  exit "$failed"
}

main
