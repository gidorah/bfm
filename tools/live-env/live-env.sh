#!/usr/bin/env bash
# BFM live environment helper (issue #18, part A: lifecycle).
#
# Primary loop (IDE-owned BFM):
#   live-env.sh prepare healthy -> live-env.sh start-dependencies
#     -> F5 "BFM - live environment" -> live-env.sh validate-dependencies
# Secondary (helper-owned BFM):
#   live-env.sh start -> live-env.sh validate
# Failover drivers: kill-primary (docker stop bfm-live-pg1), rejoin (docker start).
# Inspect/teardown: status, logs [N], stop, reset.
#
# Fixed topology (issue #18 contract, same tuples as the fast env):
#   BFM                127.0.0.1:9995   (watcher.cluster-port, server.address)
#   BFM4Patroni        127.0.0.1:9994   (reserved by the dev port split; live env must never bind it)
#   PG node 1          127.0.10.11:5432 (live-pg1 / bfm-live-pg1, primary)
#   PG node 2          127.0.10.12:5433 (live-pg2 / bfm-live-pg2, replica)
#   MiniPG per node    127.0.10.11:7779 + 127.0.10.12:7779 (real agents, same port)
#   Peer BFM           no-pair
#
# Fixed disposable test-only creds bfm/bfm everywhere (server.pguser/pgpassword,
# minipg.username/password, live PG bfm/bfm). Loopback-only, never production.
#
# Layout (all generated, git-ignored, disposable):
#   _work-tmp/live-env/application.properties   spring.config.location target
#   _work-tmp/live-env/run/bfm_status.json      BFM CWD + state (PrintWriter-truncated: readers retry)
#   _work-tmp/live-env/logs/                    pre-storage-redacted helper/BFM logs
#   _work-tmp/live-env/compose.yaml             verbatim stage of tools/live-env/compose.yaml
#   _work-tmp/live-env/fixtures/<scenario>/     verbatim stage of tools/live-env/fixtures/<scenario>/ (seed.json)
#   _work-tmp/live-env/.(launch-id|owner|scenario|helper-bfm.pid)
#   _work-tmp/live-env/.ide-bfm-active          IDE-owned BFM marker (F5 flow creates it;
#                                               this helper only respects it, never creates it)
#
# Docker interface (worker B provides tools/live-env/compose.yaml with services
# live-pg1/live-pg2 and containers bfm-live-pg1/bfm-live-pg2; compose project
# name bfm-live via the -p flag). This script only ever calls:
#   docker compose -f "$LIVE_DIR/compose.yaml" -p bfm-live ...
# Volumes are docker named volumes prefixed bfm-live- (reset = `down -v`).
# `prepare` is docker-independent (renders config, stages compose, writes
# launch-id/owner/scenario, deletes stale STATE) and must NOT require a daemon.
#
# validate-dependencies semantics (bounded polling everywhere, no blind sleeps):
# config identity + PG TCP + MiniPG HTTP + live SQL (host psql probes:
# pg_is_in_recovery roles per scenario, pg_stat_replication non-empty on the
# master, wal_log_hints=on) AND BFM evidence is mandatory (no deps-only green):
# the IDE/helper-owned BFM must listen on 127.0.0.1:9995 with /proc-proven
# config/CWD identity, staged-seed identity (scenario+pglist from
# fixtures/<scenario>/seed.json), fresh launch-id-anchored logs,
# per-scenario state, and real active/no-pair discovery. Per scenario:
#   healthy = both PG UP, pg1 primary (recovery=f) + pg2 replica (recovery=t),
#   replication flowing on pg1, wal_log_hints=on both, HEALTHY pg1 MASTER +
#   pg2 SLAVE state (exact pin per staged seed; set-wise would contradict the
#   live-SQL roles), full log floor (same lines as fast-env healthy).
#   kill-primary is phase-aware (phase detected from live pg1 TCP + recovery):
#     pre-kill  = pg1 UP + pg1 primary: healthy-like assertions (same exact pin).
#     DOWN      = pg1 TCP DOWN: fresh state shows pg2 MASTER (pg1 never
#       MASTER/SLAVE), BFM log INACCESSIBLE observation + promote/Failover
#       attempt evidence, VIP holder on pg2 via agent /minipg/checkvip.
#     rejoined  = pg1 UP + pg1 replica: pg2 MASTER + pg1 SLAVE + VIP pg2.
#
# Safety (fast-env parity, live-concrete): explicit 127.0.0.1 bind, tuple-aware
# occupancy incl. wildcard listeners, proxy bypass on every probe, pre-storage
# log redaction (fail-closed), canonical-path + symlink refusal, PID/group
# ownership enforcement (OWNER pgid SET checked on stop/reset, never just
# stored), reset refusal while IDE-owned BFM is active, refusal of external
# spring/JVM/MAVEN overrides and of the BFM deployment path
# (/etc/bfm/bfmwatcher/application.properties). Never touches repo-root
# bfm_status.json, _work-tmp/local/, or _work-tmp/fast-env/.
set -euo pipefail

# --- fixed topology ------------------------------------------------------------
BFM_IP="127.0.0.1"
BFM_PORT="9995"
PG1_IP="127.0.10.11"; PG1_PORT="5432"
PG2_IP="127.0.10.12"; PG2_PORT="5433"
MINIPG_PORT="7779"
# addr:port tuples owned by this environment (never bare ports)
PG_TUPLES="$PG1_IP:$PG1_PORT $PG2_IP:$PG2_PORT"
MINIPG_TUPLES="$PG1_IP:$MINIPG_PORT $PG2_IP:$MINIPG_PORT"
BFM_TUPLE="$BFM_IP:$BFM_PORT"

# Docker interface (worker B owns tools/live-env/compose.yaml).
COMPOSE_PROJECT="bfm-live"
PG1_CONTAINER="bfm-live-pg1"
PG2_CONTAINER="bfm-live-pg2"

# External overrides that would silently change JVM/Spring/Maven behaviour
# (SPRING_CONFIG_LOCATION gets its own message: it also covers the BFM
# deployment path /etc/bfm/bfmwatcher/application.properties).
REFUSED_ENV="_JAVA_OPTIONS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS JAVA_OPTS MAVEN_OPTS MAVEN_ARGS SPRING_PROFILES_ACTIVE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLS_DIR="$REPO_ROOT/tools/live-env"
COMPOSE_SOURCE="$TOOLS_DIR/compose.yaml"
LIVE_DIR="$REPO_ROOT/_work-tmp/live-env"
CONFIG="$LIVE_DIR/application.properties"
RUN_DIR="$LIVE_DIR/run"
STATE="$RUN_DIR/bfm_status.json"
LOGS="$LIVE_DIR/logs"
HELPER_LOG="$LOGS/live-env.log"
COMPOSE_STAGED="$LIVE_DIR/compose.yaml"
OWNER_FILE="$LIVE_DIR/.owner"
LAUNCH_FILE="$LIVE_DIR/.launch-id"
SCENARIO_FILE="$LIVE_DIR/.scenario"
PIDS_FILE="$LIVE_DIR/.pids"
HELPER_BFM_PID="$LIVE_DIR/.helper-bfm.pid"
IDE_MARKER="$LIVE_DIR/.ide-bfm-active"
FIXTURES_SOURCE_BASE="$TOOLS_DIR/fixtures"
FIXTURES_STAGED_BASE="$LIVE_DIR/fixtures"
SEED_NAME="seed.json"

VALIDATE_TIMEOUT_PG=15
VALIDATE_TIMEOUT_MINIPG=15
VALIDATE_TIMEOUT_SQL=120
VALIDATE_TIMEOUT_VIP=120
VALIDATE_TIMEOUT_BFM_HTTP=90
VALIDATE_TIMEOUT_STATE=90
VALIDATE_TIMEOUT_LOG=90
START_TIMEOUT_PG=180
START_TIMEOUT_MINIPG=120
KILL_TIMEOUT_DOWN=60
REJOIN_TIMEOUT_UP=120
REJOIN_TIMEOUT_SQL=60

# --- small utils ---------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }

# Pre-storage redaction: strip passwords / Basic creds before anything hits disk.
# Same convention as fast-env: the fixed public test-only value "bfm"
# (loopback-only live env) is NOT redacted as a literal (it would mangle every
# innocent mention); its secret-bearing form, the Basic blob YmZtOmJmbQ==
# (bfm:bfm), is covered by a static rule below. Any other configured secret is
# still redacted via redact_refresh.
# PROCsub SAFETY: redact()'s body MUST stay a single simple command (see
# tools/fast-env/fast-env.sh for why a compound body hangs bash here).
REDACT_STATIC=(
  -e 's/[Aa]uthorization:[[:space:]]*[Bb]asic [A-Za-z0-9+/=:_-]*/Authorization: Basic [REDACTED]/g'
  -e 's/YmZtOmJmbQ==/[REDACTED]/g'
  -e 's/\("[Pp]assword"[[:space:]]*:[[:space:]]*"\)[^"]*"/\1[REDACTED]"/g'
  -e 's/\([Pp]assword[=:][[:space:]]*\)[^&"'\'']*/\1[REDACTED]/g'
  -e 's/\([Tt]ls-secret[=:][[:space:]]*\)[^&"'\'']*/\1[REDACTED]/g'
)
REDACT_EXPRS=("${REDACT_STATIC[@]}")
redact() { sed "${REDACT_EXPRS[@]}"; }

redact_refresh() {
  REDACT_EXPRS=("${REDACT_STATIC[@]}")
  if [ -f "$CONFIG" ]; then
    local s
    for key in 'server\.pgpassword' 'minipg\.password' 'server\.pguser' 'minipg\.username'; do
      s="$(config_val "$key" || true)"
      # Skip the fixed public test-only "bfm" (see above); any other
      # configured secret is still redacted.
      # (if-form: a failing middle test in an && chain trips set -e.)
      if [ -n "$s" ] && [ "$s" != "bfm" ]; then
        REDACT_EXPRS+=(-e "s/$s/[REDACTED]/g")
      fi
    done
  fi
}

log() { # append redacted line to helper log (best effort; never fail)
  { printf '%s %s\n' "$(date '+%F %T')" "$* " | redact >>"$HELPER_LOG"; } 2>/dev/null || true
}

canonical() { realpath -m -- "$1"; }

# Refuse if $1 is, or contains, a symlink (walk every absolute component).
refuse_symlink() {
  local p="$1" cur="" part
  case "$p" in /*) ;; *) err "refusing non-absolute path: $p"; return 1;; esac
  IFS='/' read -ra parts <<<"$p"
  for part in "${parts[@]}"; do
    [ -z "$part" ] && { cur="/"; continue; }
    cur="${cur%/}/$part"
    if [ -L "$cur" ]; then err "refusing symlinked path component: $cur"; return 1; fi
  done
  return 0
}

# All disposable state must live at exactly _work-tmp/live-env (canonical, no
# symlinks, never /etc/bfm, never _work-tmp/local, never _work-tmp/fast-env,
# never repo root state).
guard_paths() {
  local canon_live canon_repo
  canon_live="$(canonical "$LIVE_DIR")"
  canon_repo="$(canonical "$REPO_ROOT")"
  [ "$canon_live" = "$canon_repo/_work-tmp/live-env" ] \
    || { err "refusing unexpected live-env dir: $canon_live"; return 1; }
  refuse_symlink "$canon_live" || return 1
  [ -e "$RUN_DIR" ] && refuse_symlink "$(canonical "$RUN_DIR")" || true
  case "$canon_live" in
    /etc/bfm/*|"$canon_repo/_work-tmp/local"*|"$canon_repo/_work-tmp/fast-env"*) err "refusing deployment/local/fast path: $canon_live"; return 1;;
  esac
  return 0
}

# Refuse external spring/JVM/MAVEN overrides + the BFM deployment config path.
refuse_overrides() {
  local v val
  if [ -n "${SPRING_CONFIG_LOCATION:-}" ]; then
    err "refusing external SPRING_CONFIG_LOCATION='${SPRING_CONFIG_LOCATION:-}' (helper passes an explicit spring.config.location; unset it, e.g. env -u SPRING_CONFIG_LOCATION)"
    return 1
  fi
  for v in $REFUSED_ENV; do
    val="${!v:-}"
    if [ -n "$val" ]; then
      err "refusing external $v='$val' (unset it for live-env runs, e.g. env -u $v)"
      return 1
    fi
  done
  case "${PWD:-}" in
    /etc/bfm/*) err "refusing to run from BFM deployment path: $PWD"; return 1;;
  esac
  return 0
}

# --- PID/group ownership (pgid SET, fast-env parity) -----------------------------
# OWNER_FILE holds dir=/pid=/date= plus one pgid= line per launching shell.
# `prepare` initializes the set with the current pgid; `start` appends since it
# launches helper-owned BFM. Each just recipe runs in its own shell/process
# group, so stop/reset CHECK every alive helper pid's live pgid is IN the
# recorded set, never just trust the dir line. Fail-closed: refuse to
# kill/delete when the group cannot be proven.
write_owner() { # initialize ownership of LIVE_DIR to this shell (pgid set := {current})
  printf 'dir=%s\npid=%s\npgid=%s\ndate=%s\n' \
    "$(canonical "$LIVE_DIR")" "$$" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" "$(date -u '+%FT%TZ')" >"$OWNER_FILE"
  chmod 600 "$OWNER_FILE" 2>/dev/null || true
}
owner_append() { # append current pgid to the owner set (dedupe; refresh pid/date)
  local cur_pgid canon existing merged _pg
  cur_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  case "$cur_pgid" in ''|*[!0-9]*) err "cannot determine current pgid (refusing append)"; return 1;; esac
  canon="$(canonical "$LIVE_DIR")"
  existing=""
  if [ -f "$OWNER_FILE" ]; then
    existing="$(grep -E '^pgid=' "$OWNER_FILE" 2>/dev/null | cut -d= -f2- || true)"
  fi
  merged="$(printf '%s\n%s\n' "$existing" "$cur_pgid" | grep -E '^[0-9]+$' | sort -u -n || true)"
  [ -n "$merged" ] || { err "cannot build owner pgid set (refusing append)"; return 1; }
  {
    printf 'dir=%s\npid=%s\n' "$canon" "$$"
    while IFS= read -r _pg; do
      [ -n "$_pg" ] || continue
      printf 'pgid=%s\n' "$_pg"
    done <<<"$merged"
    printf 'date=%s\n' "$(date -u '+%FT%TZ')"
  } >"$OWNER_FILE"
  chmod 600 "$OWNER_FILE" 2>/dev/null || true
}
check_owner() { # check_owner <op>
  local op="${1:-stop}"
  [ -f "$OWNER_FILE" ] || return 0
  local owner_dir owner_pid owner_pgid_lines
  owner_dir="$(grep -E '^dir=' "$OWNER_FILE" 2>/dev/null | cut -d= -f2-)"
  owner_pid="$(grep -E '^pid=' "$OWNER_FILE" 2>/dev/null | cut -d= -f2-)"
  owner_pgid_lines="$(grep -E '^pgid=' "$OWNER_FILE" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$owner_dir" ] \
    || { err "ownership file $OWNER_FILE missing dir (refusing $op)"; return 1; }
  [ "$owner_dir" = "$(canonical "$LIVE_DIR")" ] \
    || { err "ownership mismatch ($OWNER_FILE points at '$owner_dir'); refusing to $op"; return 1; }
  case "$owner_pid" in ''|*[!0-9]*) err "ownership file $OWNER_FILE has invalid pid '$owner_pid' (refusing $op)"; return 1;; esac
  [ -n "$owner_pgid_lines" ] \
    || { err "ownership file $OWNER_FILE has invalid pgid '' (refusing $op)"; return 1; }
  local _pg set_display
  while IFS= read -r _pg; do
    case "$_pg" in ''|*[!0-9]*) err "ownership file $OWNER_FILE has invalid pgid '$_pg' (refusing $op)"; return 1;; esac
  done <<<"$owner_pgid_lines"
  set_display="$(printf '%s\n' "$owner_pgid_lines" | paste -sd, - | sed 's/,/, /g')"
  # When the launching pid is still alive, its live pgid must be IN the set.
  if kill -0 "$owner_pid" 2>/dev/null; then
    local live_pgid
    live_pgid="$(ps -o pgid= -p "$owner_pid" 2>/dev/null | tr -d ' ')"
    [ -n "$live_pgid" ] \
      || { err "cannot prove owner pid=$owner_pid group (refusing $op)"; return 1; }
    if ! printf '%s\n' "$owner_pgid_lines" | grep -Fxq "$live_pgid"; then
      err "ownership group mismatch (owner pid=$owner_pid live pgid=$live_pgid not in recorded pgid set [$set_display]; refusing $op)"
      return 1
    fi
  fi
  # Helper-owned pids must belong to the recorded SET while alive.
  local f p actual
  for f in "$PIDS_FILE" "$HELPER_BFM_PID"; do
    [ -f "$f" ] || continue
    while read -r p; do
      [ -n "$p" ] || continue
      kill -0 "$p" 2>/dev/null || continue
      actual="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"
      [ -n "$actual" ] \
        || { err "cannot prove helper pid=$p group (refusing $op)"; return 1; }
      if ! printf '%s\n' "$owner_pgid_lines" | grep -Fxq "$actual"; then
        err "helper pid=$p pgid=$actual outside owner pgid set [$set_display] (refusing $op; foreign pid?)"
        return 1
      fi
    done <"$f"
  done
  return 0
}

# --- tuple-aware occupancy ------------------------------------------------------
# tuple_listening <ip> <port>: true when anything (incl. 0.0.0.0 / :: wildcard)
# holds the exact addr:port tuple. Prefers ss, falls back to /proc/net/tcp*.
# Java binds dual-stack, so ss shows IPv4-mapped IPv6 ([::ffff:127.0.0.1]:9995):
# normalize that form to plain IPv4 before comparing. SS_BIN is overridable
# for tests (fixture printer emitting ss -tlnH-shaped lines).
tuple_listening() {
  local ip="$1" port="$2" line
  if command -v "${SS_BIN:-ss}" >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if printf '%s' "$line" | awk -v IP="$ip" -v P="$port" '
        { f=$4; sub(/%[^: ]*:/, ":", f); n=split(f,a,":"); p=a[n];
          addr=f; sub(/:[^:]*$/, "", addr); gsub(/^\[|\]$/, "", addr);
          sub(/^::[fF]{4}:/, "", addr);
          if (p==P && (addr==IP || addr=="0.0.0.0" || addr=="*" || addr=="::")) exit 0; exit 1 }'; then
        return 0
      fi
    done < <("${SS_BIN:-ss}" -tlnH 2>/dev/null || true)
    return 1
  fi
  # Fallback: /proc/net/tcp + tcp6, little-endian hex, LISTEN == 0A.
  # tcp6 shows mapped binds as 0000000000000000FFFF0000+H; strip that prefix.
  local f hex_ip hex_port
  hex_port=$(printf '%04X' "$port")
  hex_ip=$(printf '%s' "$ip" | awk -F. '{printf "%02X%02X%02X%02X",$4,$3,$2,$1}')
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    if awk -v H="$hex_ip" -v P="$hex_port" 'NR>1 && $4=="0A" {
        split($2,a,":"); ip=toupper(a[1]); port=a[2];
        sub(/^0000000000000000FFFF0000/, "", ip);
        if (port==P && (ip==H || ip=="00000000" || ip=="00000000000000000000000000000000")) exit 0
      } END{exit 1}' "$f"; then
      return 0
    fi
  done
  return 1
}

# listener_pid <ip> <port>: print PID holding the tuple (ss only; empty if unknown).
listener_pid() {
  local ip="$1" port="$2"
  command -v ss >/dev/null 2>&1 || return 0
  ss -tlnpH 2>/dev/null | awk -v IP="$ip" -v P="$port" '
    { f=$4; sub(/%[^: ]*:/, ":", f); n=split(f,a,":"); p=a[n];
      addr=f; sub(/:[^:]*$/, "", addr); gsub(/^\[|\]$/, "", addr);
      sub(/^::[fF]{4}:/, "", addr);
      if (p==P && (addr==IP || addr=="0.0.0.0" || addr=="*" || addr=="::")) {
        if (match($0, /pid=[0-9]+/)) { print substr($0, RSTART+4, RLENGTH-4); exit }
      } }' || true
}

# tcp_probe <ip> <port>: direct TCP connect (no proxy involved, single attempt).
tcp_probe() {
  python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()" \
    "$1" "$2" 2>/dev/null
}

# http_probe <url> [user:pass]: curl with proxy bypassed (fail-closed on proxy).
http_probe() {
  local url="$1" creds="${2:-}"
  local args=(--noproxy '*' --max-time 5 -s -o /dev/null -w '%{http_code}')
  [ -n "$creds" ] && args+=(-u "$creds")
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    curl "${args[@]}" "$url" 2>/dev/null
}

# http_200 <url> [user:pass]: true iff the proxy-bypassed probe answers HTTP 200.
http_200() {
  [ "$(http_probe "$1" "${2:-}" || true)" = "200" ]
}

# poll_until <timeout_s> <cmd...>: bounded polling, no blind sleeps.
poll_until() {
  local timeout="$1"; shift
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  return 1
}

config_val() { # config_val <key>: raw value from generated CONFIG
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null | sed 's/.*=[[:space:]]*//' | tail -n 1
}

# --- docker interface ------------------------------------------------------------
# All docker traffic goes through compose() with the contract project name.
compose() {
  docker compose -f "$COMPOSE_STAGED" -p "$COMPOSE_PROJECT" "$@"
}

docker_ok() { docker info >/dev/null 2>&1; }

require_compose() {
  [ -f "$COMPOSE_STAGED" ] \
    || { err "compose file $COMPOSE_STAGED absent (run '$0 prepare [healthy|kill-primary]' first; the docker side is owned by worker B via tools/live-env/compose.yaml)"; return 1; }
  docker_ok \
    || { err "docker daemon unreachable (docker info failed; start Docker, then re-run)"; return 1; }
  return 0
}

# pg_exec <ip> <port> <sql>: live SQL via the host psql client (live-env
# prerequisite; used by validate/rejoin probes, never by BFM itself).
# Single-line trimmed output; empty on failure. Creds come from CONFIG
# (PGPASSWORD env, never CLI/logged).
pg_exec() {
  local ip="$1" port="$2"; shift 2
  local pguser pgpass
  pguser="$(config_val 'server\.pguser')"
  pgpass="$(config_val 'server\.pgpassword')"
  [ -n "$pguser" ] && [ -n "$pgpass" ] \
    || { err "cannot run live SQL: server.pguser/pgpassword missing in $CONFIG"; return 1; }
  command -v psql >/dev/null 2>&1 \
    || { err "psql client is missing (live-env prerequisite for live SQL probes; install postgresql-client)"; return 1; }
  PGPASSWORD="$pgpass" psql -h "$ip" -p "$port" -U "$pguser" -d postgres \
    -v ON_ERROR_STOP=1 -tAc "$*" 2>/dev/null \
    | tail -n 1 | tr -d '[:space:]'
}

# sql_is <ip> <port> <sql> <want>: true iff live SQL returns exactly <want>.
sql_is() {
  [ "$(pg_exec "$1" "$2" "$3" || true)" = "$4" ]
}

# repl_flowing <ip> <port>: true iff pg_stat_replication is non-empty.
repl_flowing() {
  local n
  n="$(pg_exec "$1" "$2" "SELECT count(*) FROM pg_stat_replication;" || true)"
  case "$n" in ''|0) return 1;; *) return 0;; esac
}

# pg_ready <ip> <port>: true iff PG answers a live query (any recovery value).
pg_ready() {
  case "$(pg_exec "$1" "$2" "SELECT pg_is_in_recovery();" || true)" in
    t|f) return 0;;
    *) return 1;;
  esac
}

# minipg_body <ip> <route>: proxy-bypassed MiniPG agent body with minipg creds.
minipg_body() {
  local ip="$1" route="$2"
  local muser mpass
  muser="$(config_val 'minipg\.username')"; mpass="$(config_val 'minipg\.password')"
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    curl --noproxy '*' --max-time 5 -s -u "$muser:$mpass" "http://$ip:$MINIPG_PORT$route" 2>/dev/null || true
}

# vip_on <ip>: true iff that node's agent /minipg/checkvip names <ip> as holder.
# Contract: the agent answers the holder address in the body (worker B aligns
# the images to this); BFM's own vipUp/vipDown flow moves it on failover.
vip_on() {
  local ip="$1" body
  body="$(minipg_body "$ip" "/minipg/checkvip" || true)"
  [ -n "$body" ] && printf '%s' "$body" | grep -qF "$ip"
}

# Render CONFIG from the dev/live-env template (or the inline fallback).
# Credentials are fixed test-only bfm/bfm (loopback-only); no substitution.
render_config() { # render_config <launch> <scenario>
  local launch_id="$1" scenario="$2"
  local template="$REPO_ROOT/dev/live-env/application.properties"
  if [ -f "$template" ]; then
    cp "$template" "$CONFIG"
    note "config: TEMPLATE $template"
  else
    note "config: WARN template $template absent; using inline fallback"
    cat >"$CONFIG" <<EOF
# BFM live-environment config (INLINE FALLBACK - template absent).
app.bfm-hc-clustername          = BFMCluster
app.custom-logo-path            =
server.pguser                   = bfm
server.pgpassword               = bfm
server.address                  = 127.0.0.1
watcher.cluster-port            = 9995
watcher.cluster-pair            = no-pair
app.timeout-ignorance-count     = 3
bfm.watch-strategy              = availability
server.pglist                   = 127.0.10.11:5432,127.0.10.12:5433
bfm.user-crypted                = false
bfm.use-tls                     = false
minipg.use-tls                  = false
bfm.tls-secret                  =
bfm.tls-key-store               = bfm.p12
minipg.username                 = bfm
minipg.password                 = bfm
minipg.port                     = 7779
heartbeat.interval              = 10
heartbeat.query                 = select 1
bfm.data-loss-tolerance         = 120K
bfm.status-file-expire          = 1H
bfm.ex-master-behavior          = rejoin
bfm.basebackup-slave-join       = true
bfm.mail-notification-enabled   = false
spring.mail.host=localhost
spring.mail.port=25
spring.mail.username=
spring.mail.password=
spring.mail.properties.mail.smtp.auth=false
spring.mail.properties.mail.smtp.starttls.enable=false
logging.file.name=../logs/app.log
EOF
  fi
  # Fail-closed: no unsubstituted placeholders may remain.
  local tok
  for tok in '@@LIVE_PGUSER@@' '@@LIVE_PGPASSWORD@@' '@@LIVE_MINIPG_USER@@' '@@LIVE_MINIPG_PASSWORD@@'; do
    if grep -qF "$tok" "$CONFIG"; then
      err "unsubstituted token $tok left in $CONFIG (template/contract drift)"
      return 1
    fi
  done
  # Prepend the launch header without touching the rendered body.
  local tmp; tmp="$(mktemp)"
  {
    printf '# GENERATED by tools/live-env/live-env.sh (DO NOT edit, DO NOT use in production).\n'
    printf '# launch-id=%s scenario=%s\n' "$launch_id" "$scenario"
    cat "$CONFIG"
  } >"$tmp"
  cat "$tmp" >"$CONFIG"
  rm -f "$tmp"
  chmod 600 "$CONFIG"
}

# launch_bg_redacted <logfile> <cmd...>: background cmd with stdout/stderr
# piped through pre-storage redaction; echoes the CHILD pid (process
# substitution keeps $! as the real child, unlike a plain pipeline).
launch_bg_redacted() {
  local logf="$1"; shift
  "$@" > >(redact >>"$logf" 2>/dev/null) 2>&1 &
  echo $!
}

# no_proxy_env: strip proxy vars for locally-bound child processes.
no_proxy_env() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy "$@"
}

# --- scenario ----------------------------------------------------------------------
# Scenario owning this run (from .scenario, fallback healthy for runs prepared
# before scenarios existed). Only healthy|kill-primary.
current_scenario() {
  local s="healthy"
  if [ -f "$SCENARIO_FILE" ]; then
    s="$(cat "$SCENARIO_FILE" 2>/dev/null || echo healthy)"
  fi
  case "$s" in
    healthy|kill-primary) printf '%s' "$s";;
    *) printf 'healthy';;
  esac
}

# --- prepare ---------------------------------------------------------------------
# Docker-independent: renders config, stages compose, writes
# launch-id/owner/scenario, deletes stale STATE. Never touches the daemon.
cmd_prepare() {
  local scenario="${1:-healthy}"
  refuse_overrides || return 1
  guard_paths || return 1
  case "$scenario" in
    healthy|kill-primary) ;;
    *) err "unknown scenario '$scenario' is deferred (v1 supports only 'healthy' and 'kill-primary'; follow-ups: replica-data-loss, lag-threshold, switchover-tablespaces, pair-takeover)"; return 1;;
  esac
  # Scenario identity: the recorded scenario drives start/validate/
  # kill-primary/rejoin and is rewritten only by an explicit re-prepare.
  # Re-prepare while anything is live still refuses first (IDE marker,
  # helper pids/BFM, BFM tuple below), so a running stack can never be
  # flipped underneath BFM: that path requires stop/reset.
  if [ -f "$IDE_MARKER" ]; then
    err "IDE-owned BFM is active ($IDE_MARKER); stop it before re-preparing"
    return 1
  fi
  if [ -f "$PIDS_FILE" ] && pids_alive "$PIDS_FILE"; then
    err "helper-owned processes are running (run '$0 stop' first)"
    return 1
  fi
  if [ -f "$HELPER_BFM_PID" ] && pids_alive "$HELPER_BFM_PID"; then
    err "helper-owned BFM is running (run '$0 stop' first)"
    return 1
  fi
  if tuple_listening "$BFM_IP" "$BFM_PORT"; then
    err "BFM tuple $BFM_TUPLE is occupied; stop that BFM before re-preparing"
    return 1
  fi

  mkdir -p "$RUN_DIR" "$LOGS"
  local launch_id="live-$(date +%s)-$$-$RANDOM"

  render_config "$launch_id" "$scenario" || return 1
  redact_refresh
  if [ -f "$SCENARIO_FILE" ] && [ "$(cat "$SCENARIO_FILE" 2>/dev/null || true)" != "$scenario" ]; then
    note "scenario: SWITCH to '$scenario' by idle re-prepare (was '$(cat "$SCENARIO_FILE")'; reset first if a live stack is up)"
  fi
  printf '%s\n' "$launch_id" >"$LAUNCH_FILE"
  printf '%s\n' "$scenario" >"$SCENARIO_FILE"
  write_owner
  chmod 600 "$LAUNCH_FILE" "$SCENARIO_FILE" 2>/dev/null || true

  # Stage the docker side verbatim (worker B owns tools/live-env/compose.yaml).
  # Absent source is a warning here (prepare stays docker-independent);
  # start-dependencies fails clearly without the staged file.
  if [ -f "$COMPOSE_SOURCE" ]; then
    cp "$COMPOSE_SOURCE" "$COMPOSE_STAGED"
    chmod 600 "$COMPOSE_STAGED" 2>/dev/null || true
    note "compose: STAGED $COMPOSE_SOURCE -> $COMPOSE_STAGED (verbatim)"
  else
    note "compose: WARN source $COMPOSE_SOURCE absent (docker side owned by worker B); '$0 start-dependencies' will fail clearly until it lands"
  fi
  # Stage the per-scenario seed verbatim (fast-env fixtures/<scenario>/ shape).
  # Fail-closed: prepare must refuse when the source is missing/empty so a
  # run can never validate against a silently absent seed.
  local fixtures_src="$FIXTURES_SOURCE_BASE/$scenario" fixtures_dst="$FIXTURES_STAGED_BASE/$scenario"
  mkdir -p "$fixtures_dst"
  if [ -d "$fixtures_src" ] && [ -n "$(ls -A "$fixtures_src" 2>/dev/null)" ]; then
    cp -r "$fixtures_src/." "$fixtures_dst/"
    note "fixtures: COPY $fixtures_src -> $fixtures_dst"
  else
    err "fixtures source $fixtures_src missing/empty (fail-closed; expected fixtures/$scenario/$SEED_NAME)"
    return 1
  fi
  [ -s "$fixtures_dst/$SEED_NAME" ] \
    || { err "staged seed $fixtures_dst/$SEED_NAME missing/empty (fail-closed; re-run '$0 prepare $scenario')"; return 1; }
  # Stale disposable state from a previous run must not poison validation.
  # The dev/live-env seed is reference-only; BFM rewrites STATE on its loop.
  rm -f "$STATE"
  log "prepare scenario=$scenario launch=$launch_id"
  note "CONFIG=$CONFIG"
  note "RUN_DIR=$RUN_DIR"
  note "STATE=$STATE (fresh; BFM rewrites it on its check loop)"
  note "LOG_DIR=$LOGS"
  note "launch-id=$launch_id"
  note "server.pglist=$(config_val 'server\.pglist')"
}

# --- pid helpers ---------------------------------------------------------------
pids_alive() { # pids_alive <file>: true if any listed PID is alive
  local p
  [ -f "$1" ] || return 1
  while read -r p; do
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
  done <"$1"
  return 1
}

# --- start-dependencies ----------------------------------------------------------
# Docker owns adopt-vs-launch (compose up is idempotent); only the BFM tuple
# still needs an occupancy guard (see `start`). Brings up live-pg1/live-pg2
# (PG + per-node MiniPG agents; healthy seeding happens in the containers),
# then bounded-waits PG TCP tuples + MiniPG HTTP /minipg/pgstatus with minipg
# creds. For kill-primary this yields the pre-kill state; `kill-primary`
# drives the DOWN phase from here.
cmd_start_dependencies() {
  refuse_overrides || return 1
  guard_paths || return 1
  [ -f "$CONFIG" ] || { err "not prepared (run '$0 prepare [healthy|kill-primary]' first)"; return 1; }
  redact_refresh
  require_compose || return 1
  mkdir -p "$LOGS"

  local scenario
  scenario="$(current_scenario)"
  note "start-dependencies: scenario=$scenario (project=$COMPOSE_PROJECT)"
  if ! compose up -d --build 2>&1 | redact >>"$HELPER_LOG" 2>/dev/null; then
    err "docker compose up -d --build failed (see $HELPER_LOG)"
    return 1
  fi
  log "start-dependencies compose up -d --build ok"

  local t ip port muser mpass
  muser="$(config_val 'minipg\.username')"; mpass="$(config_val 'minipg\.password')"
  for t in $PG_TUPLES; do
    ip="${t%%:*}"; port="${t##*:}"
    if poll_until "$START_TIMEOUT_PG" tcp_probe "$ip" "$port"; then
      note "pg $t: UP"
    else
      err "pg $t: NOT LISTENING after ${START_TIMEOUT_PG}s (see 'docker compose -f $COMPOSE_STAGED -p $COMPOSE_PROJECT ps/logs')"
      return 1
    fi
  done
  for t in $MINIPG_TUPLES; do
    ip="${t%%:*}"; port="${t##*:}"
    if poll_until "$START_TIMEOUT_MINIPG" http_200 "http://$ip:$port/minipg/pgstatus" "$muser:$mpass"; then
      note "minipg $t: HTTP 200 (/minipg/pgstatus)"
    else
      err "minipg $t: no HTTP 200 on /minipg/pgstatus after ${START_TIMEOUT_MINIPG}s (want 200 with minipg creds)"
      return 1
    fi
  done
  log "start-dependencies: pg + minipg endpoints listening"
  note "start-dependencies: pg + minipg endpoints listening"
  return 0
}

# --- validate-dependencies -------------------------------------------------------
# Config identity + PG TCP + MiniPG HTTP + live SQL + MANDATORY BFM evidence
# (fails when the IDE/helper-owned BFM is absent or identity cannot be proven).
# kill-primary is phase-aware: pg1 TCP DOWN -> failover assertions; pg1 UP ->
# live recovery decides pre-kill (pg1 primary, healthy-like) vs rejoined
# (pg2 MASTER + pg1 SLAVE + VIP pg2).
cmd_validate_dependencies() {
  refuse_overrides || return 1
  guard_paths || return 1
  [ -f "$CONFIG" ] || { err "not prepared (run '$0 prepare [healthy|kill-primary]' first)"; return 1; }
  redact_refresh
  mkdir -p "$LOGS"
  local launch_id="unknown"
  [ -f "$LAUNCH_FILE" ] && launch_id="$(cat "$LAUNCH_FILE")"
  local scenario
  scenario="$(current_scenario)"
  note "validate-dependencies: scenario=$scenario (launch-id=$launch_id)"

  # (a) config identity: expected loopback topology, never prod values.
  local pglist
  pglist="$(config_val 'server\.pglist')"
  [ "$pglist" = "127.0.10.11:5432,127.0.10.12:5433" ] \
    || { err "unexpected server.pglist='$pglist' (want 127.0.10.11:5432,127.0.10.12:5433)"; return 1; }
  [ "$(config_val 'watcher\.cluster-port')" = "9995" ] \
    || { err "unexpected watcher.cluster-port (want 9995)"; return 1; }
  [ "$(config_val 'watcher\.cluster-pair')" = "no-pair" ] \
    || { err "unexpected watcher.cluster-pair (want no-pair)"; return 1; }
  [ "$(config_val 'minipg\.port')" = "7779" ] \
    || { err "unexpected minipg.port (want 7779)"; return 1; }
  [ "$(config_val 'server\.address')" = "127.0.0.1" ] \
    || { err "unexpected server.address (want 127.0.0.1 explicit bind)"; return 1; }
  case "$pglist" in 127.*) ;; *) err "refusing non-loopback pglist: $pglist"; return 1;; esac
  local pguser pgpass muser mpass
  pguser="$(config_val 'server\.pguser')"; pgpass="$(config_val 'server\.pgpassword')"
  muser="$(config_val 'minipg\.username')"; mpass="$(config_val 'minipg\.password')"
  [ -n "$pgpass" ] && [ -n "$mpass" ] \
    || { err "cannot prove redaction: generated secrets missing in $CONFIG"; return 1; }

  # (a2) staged seed identity: the seed staged at prepare time must name this
  # scenario and the same pglist pair, or validation fails closed.
  local seed="$FIXTURES_STAGED_BASE/$scenario/$SEED_NAME"
  [ -f "$seed" ] \
    || { err "seed $seed missing (run '$0 prepare $scenario' first)"; return 1; }
  if ! python3 - "$seed" "$scenario" "$pglist" <<'EOF'; then
import json, sys
seedf, want_scenario, want_pglist = sys.argv[1], sys.argv[2], sys.argv[3]
seed = json.load(open(seedf))  # raises on corrupt seed -> fail
assert seed.get("scenario") == want_scenario, seed
assert ",".join(seed.get("pglist", [])) == want_pglist, seed
EOF
    err "seed $seed does not match scenario='$scenario' pglist='$pglist' (stale fixtures? re-run '$0 prepare $scenario')"
    return 1
  fi
  note "seed: $seed matches scenario=$scenario"

  # (b) live PG TCP: bounded polling of every tuple (proxy-free).
  # kill-primary DOWN phase: pg1 must stay DOWN (absence is the point there).
  local phase="healthy"
  if [ "$scenario" = "kill-primary" ] && ! tcp_probe "$PG1_IP" "$PG1_PORT"; then
    phase="down"
  fi
  local t ip port
  if [ "$phase" = "down" ]; then
    if tuple_listening "$PG1_IP" "$PG1_PORT" || tcp_probe "$PG1_IP" "$PG1_PORT"; then
      err "pg $PG1_IP:$PG1_PORT: reachable but DOWN phase requires it stopped (run '$0 kill-primary' first, or '$0 rejoin' for the rejoined phase)"
      return 1
    fi
    note "pg $PG1_IP:$PG1_PORT: DOWN (failover phase)"
    if poll_until "$VALIDATE_TIMEOUT_PG" tcp_probe "$PG2_IP" "$PG2_PORT"; then
      note "pg $PG2_IP:$PG2_PORT: UP"
    else
      err "pg $PG2_IP:$PG2_PORT: NOT LISTENING after ${VALIDATE_TIMEOUT_PG}s (run '$0 start-dependencies')"
      return 1
    fi
  else
    for t in $PG_TUPLES; do
      ip="${t%%:*}"; port="${t##*:}"
      if poll_until "$VALIDATE_TIMEOUT_PG" tcp_probe "$ip" "$port"; then
        note "pg $t: UP"
      else
        err "pg $t: NOT LISTENING after ${VALIDATE_TIMEOUT_PG}s (run '$0 start-dependencies')"
        return 1
      fi
    done
  fi

  # (c) MiniPG HTTP speaks (/minipg/pgstatus with minipg creds, proxy-bypassed).
  # DOWN phase: pg1's agent goes down with its container (absence is the point);
  # only pg2's agent must answer 200 there.
  local want_minipg="$MINIPG_TUPLES"
  [ "$phase" = "down" ] && want_minipg="$PG2_IP:$MINIPG_PORT"
  local code
  for t in $want_minipg; do
    ip="${t%%:*}"; port="${t##*:}"
    if poll_until "$VALIDATE_TIMEOUT_MINIPG" http_200 "http://$ip:$port/minipg/pgstatus" "$muser:$mpass"; then
      note "minipg $t: HTTP 200 (/minipg/pgstatus)"
    else
      code="$(http_probe "http://$ip:$port/minipg/pgstatus" "$muser:$mpass" || true)"
      err "minipg $t: HTTP ${code:-000} on /minipg/pgstatus after ${VALIDATE_TIMEOUT_MINIPG}s (minipg agent missing or misconfigured; want 200 with minipg creds)"
      return 1
    fi
  done
  if [ "$phase" = "down" ]; then
    note "minipg $PG1_IP:$MINIPG_PORT: skipped (pg1 container stopped in DOWN phase)"
  fi

  # (d) live SQL via host psql (validate/rejoin probes; never BFM itself).
  # wal_log_hints=on is a rejoin prerequisite (#14): asserted on every live node.
  if [ "$phase" = "down" ]; then
    poll_until "$VALIDATE_TIMEOUT_SQL" sql_is "$PG2_IP" "$PG2_PORT" "SELECT pg_is_in_recovery();" "f" \
      || { err "live SQL: $PG2_IP:$PG2_PORT still in recovery after ${VALIDATE_TIMEOUT_SQL}s (want promoted primary, recovery=f)"; return 1; }
    note "live SQL: $PG2_IP:$PG2_PORT recovery=f (promoted primary)"
    [ "$(pg_exec "$PG2_IP" "$PG2_PORT" "SHOW wal_log_hints;" || true)" = "on" ] \
      || { err "live SQL: $PG2_IP:$PG2_PORT wal_log_hints != on (pg_rewind rejoin prerequisite)"; return 1; }
    note "live SQL: $PG2_IP:$PG2_PORT wal_log_hints=on"
  else
    # pg1 UP: live recovery decides pre-kill (pg1 primary) vs rejoined (pg1 replica).
    local r1 r2
    r1="$(pg_exec "$PG1_IP" "$PG1_PORT" "SELECT pg_is_in_recovery();" || true)"
    r2="$(pg_exec "$PG2_IP" "$PG2_PORT" "SELECT pg_is_in_recovery();" || true)"
    case "$r1/$r2" in
      f/t)
        [ "$scenario" = "kill-primary" ] && phase="pre-kill"
        note "live SQL: $PG1_IP:$PG1_PORT recovery=f (primary), $PG2_IP:$PG2_PORT recovery=t (replica)"
        poll_until "$VALIDATE_TIMEOUT_SQL" repl_flowing "$PG1_IP" "$PG1_PORT" \
          || { err "live SQL: pg_stat_replication empty on $PG1_IP:$PG1_PORT after ${VALIDATE_TIMEOUT_SQL}s (want replication flowing)"; return 1; }
        note "live SQL: pg_stat_replication non-empty on $PG1_IP:$PG1_PORT"
        ;;
      t/f)
        if [ "$scenario" = "kill-primary" ]; then
          phase="rejoined"
          note "live SQL: $PG2_IP:$PG2_PORT recovery=f (primary), $PG1_IP:$PG1_PORT recovery=t (rejoined replica)"
          poll_until "$VALIDATE_TIMEOUT_SQL" repl_flowing "$PG2_IP" "$PG2_PORT" \
            || { err "live SQL: pg_stat_replication empty on $PG2_IP:$PG2_PORT after ${VALIDATE_TIMEOUT_SQL}s (want replica rejoined)"; return 1; }
          note "live SQL: pg_stat_replication non-empty on $PG2_IP:$PG2_PORT"
        else
          err "live SQL: unexpected roles in scenario 'healthy' ($PG1_IP:$PG1_PORT recovery=t, $PG2_IP:$PG2_PORT recovery=f; want pg1 primary)"
          return 1
        fi
        ;;
      *)
        err "live SQL: roles unreadable - live PG responses missing or ambiguous ($PG1_IP:$PG1_PORT recovery='${r1:-?}', $PG2_IP:$PG2_PORT recovery='${r2:-?}'; want f/t, t/f, or pg1 stopped; run '$0 start-dependencies')"
        return 1
        ;;
    esac
    local tuple ip port
    for tuple in $PG_TUPLES; do
      ip="${tuple%%:*}"; port="${tuple##*:}"
      [ "$(pg_exec "$ip" "$port" "SHOW wal_log_hints;" || true)" = "on" ] \
        || { err "live SQL: $ip:$port wal_log_hints != on (pg_rewind rejoin prerequisite)"; return 1; }
    done
    note "live SQL: wal_log_hints=on on both nodes"
  fi
  note "validate-dependencies: phase=$phase (scenario=$scenario)"
  log "validate-dependencies launch=$launch_id scenario=$scenario phase=$phase"

  # (e) BFM evidence is REQUIRED: fail when the IDE/helper-owned BFM is absent.
  if ! tuple_listening "$BFM_IP" "$BFM_PORT"; then
    err "BFM $BFM_TUPLE: not listening - BFM evidence is required (start it via F5 'BFM - live environment' or '$0 start', then re-run)"
    return 1
  fi

  # -- BFM is present: listener alone is insufficient; prove config/CWD identity.
  local bfm_pid cfg_canon run_canon
  bfm_pid="$(listener_pid "$BFM_IP" "$BFM_PORT")"
  cfg_canon="$(canonical "$CONFIG")"; run_canon="$(canonical "$RUN_DIR")"
  if [ -n "$bfm_pid" ] && [ -d "/proc/$bfm_pid" ]; then
    local cwd cmd
    cwd="$(readlink "/proc/$bfm_pid/cwd" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' <"/proc/$bfm_pid/cmdline" 2>/dev/null || true)"
    if [ "$cwd" = "$run_canon" ] && [[ "$cmd" == *"$cfg_canon"* ]]; then
      if [ -f "$HELPER_BFM_PID" ] && [ "$(cat "$HELPER_BFM_PID" 2>/dev/null)" = "$bfm_pid" ]; then
        note "BFM $BFM_TUPLE: helper-owned pid=$bfm_pid (config+CWD identity OK)"
      else
        note "BFM $BFM_TUPLE: IDE-owned pid=$bfm_pid (config+CWD identity OK)"
      fi
    else
      err "BFM on $BFM_TUPLE failed identity check: pid=$bfm_pid cwd='$cwd' (want $run_canon), cmdline lacks $cfg_canon"
      return 1
    fi
  else
    err "BFM tuple $BFM_TUPLE is occupied but the owning PID is not visible (cannot prove config/CWD identity via /proc)"
    return 1
  fi

  # -- BFM HTTP: Basic auth with CONFIG creds, proxy bypassed, bounded poll.
  poll_until "$VALIDATE_TIMEOUT_BFM_HTTP" http_probe "http://$BFM_IP:$BFM_PORT/bfm/is-alive" "$pguser:$pgpass" || true
  code="$(http_probe "http://$BFM_IP:$BFM_PORT/bfm/is-alive" "$pguser:$pgpass" || true)"
  case "$code" in
    200) note "BFM $BFM_TUPLE: /bfm/is-alive HTTP 200";;
    *) err "BFM $BFM_TUPLE: /bfm/is-alive HTTP ${code:-000} after ${VALIDATE_TIMEOUT_BFM_HTTP}s (want 200 with CONFIG creds)"; return 1;;
  esac

  # -- bfm_status.json: retry-on-truncated-write + freshness vs launch-id.
  # Roles are pinned exact per the staged seed (healthy/pre-kill: pg1 MASTER
  # + pg2 SLAVE; rejoined: pg2 MASTER + pg1 SLAVE) so state can never
  # contradict the live-SQL roles.
  # healthy/pre-kill: HEALTHY with pg1 MASTER + pg2 SLAVE.
  # down: fresh state shows pg2 MASTER while pg1 is never MASTER/SLAVE
  #   (INACCESSIBLE or absent); clusterStatus is presence-only (failover()
  #   ends HEALTHY unconditionally, so HEALTHY proves nothing here).
  # rejoined: HEALTHY with pg2 MASTER + pg1 SLAVE.
  note "waiting for fresh $STATE (launch-id=$launch_id, phase=$phase) ..."
  local st_file
  st_file="$(mktemp)"
  if [ "$phase" = "down" ]; then
    if ! poll_until "$VALIDATE_TIMEOUT_STATE" python3 - "$STATE" "$st_file" "$seed" <<'EOF'
import json, sys
state, out, seedf = sys.argv[1], sys.argv[2], sys.argv[3]
seed = json.load(open(seedf))
d = json.load(open(state))  # raises on truncated/partial write -> poll retries
got = {s["address"]: s.get("databaseStatus") for s in d.get("clusterServers", [])}
promoted = (seed.get("phases") or {}).get("down", {}).get("promoted")
assert promoted == "127.0.10.12:5433", seed
assert got.get(promoted) == "MASTER", got
assert got.get("127.0.10.11:5432") not in ("MASTER", "SLAVE"), got
open(out, "w").write(json.dumps({"clusterStatus": d.get("clusterStatus"), "roles": got}, sort_keys=True))
EOF
    then
      err "state check failed after ${VALIDATE_TIMEOUT_STATE}s: fresh state must show 127.0.10.12:5433=MASTER with 127.0.10.11:5432 never MASTER/SLAVE (tolerant of truncated rewrites; see $STATE)"
      rm -f "$st_file"
      return 1
    fi
    note "state: fresh roles=$(cat "$st_file") (any clusterStatus accepted; HEALTHY is never success evidence here)"
  elif [ "$phase" = "rejoined" ]; then
    if ! poll_until "$VALIDATE_TIMEOUT_STATE" python3 - "$STATE" "$st_file" "$seed" <<'EOF'
import json, sys
state, out, seedf = sys.argv[1], sys.argv[2], sys.argv[3]
seed = json.load(open(seedf))
d = json.load(open(state))  # raises on truncated/partial write -> poll retries
assert d.get("clusterStatus") == "HEALTHY", d.get("clusterStatus")
got = {s["address"]: s.get("databaseStatus") for s in d.get("clusterServers", [])}
assert set(got) == {"127.0.10.11:5432", "127.0.10.12:5433"}, got
assert sorted(got.values()) == ["MASTER", "SLAVE"], got
assert got.get("127.0.10.12:5433") == "MASTER", got
assert got.get("127.0.10.11:5432") == "SLAVE", got
exp = (seed.get("phases") or {}).get("rejoined", {}).get("roles")
assert exp == {"127.0.10.12:5433": "MASTER", "127.0.10.11:5432": "SLAVE"}, seed
assert got == exp, (got, exp)
open(out, "w").write(json.dumps(got, sort_keys=True))
EOF
    then
      err "state check failed after ${VALIDATE_TIMEOUT_STATE}s: want clusterStatus=HEALTHY with 127.0.10.12:5433=MASTER + 127.0.10.11:5432=SLAVE (tolerant of truncated rewrites; see $STATE)"
      rm -f "$st_file"
      return 1
    fi
    note "state: HEALTHY rejoined roles=$(cat "$st_file")"
  else
    if ! poll_until "$VALIDATE_TIMEOUT_STATE" python3 - "$STATE" "$st_file" "$seed" <<'EOF'
import json, sys
state, out, seedf = sys.argv[1], sys.argv[2], sys.argv[3]
seed = json.load(open(seedf))
d = json.load(open(state))  # raises on truncated/partial write -> poll retries
assert d.get("clusterStatus") == "HEALTHY", d.get("clusterStatus")
got = {s["address"]: s.get("databaseStatus") for s in d.get("clusterServers", [])}
assert set(got) == {"127.0.10.11:5432", "127.0.10.12:5433"}, got
# Exact pin: pg1 MASTER + pg2 SLAVE. The live-SQL path pins pg1 as primary,
# so set-wise acceptance here would let contradictory evidence green.
assert got.get("127.0.10.11:5432") == "MASTER", got
assert got.get("127.0.10.12:5433") == "SLAVE", got
exp = seed.get("roles")
if exp is None:
    exp = (seed.get("phases") or {}).get("pre-kill", {}).get("roles")
assert exp == {"127.0.10.11:5432": "MASTER", "127.0.10.12:5433": "SLAVE"}, seed
assert got == exp, (got, exp)
open(out, "w").write(json.dumps(got, sort_keys=True))
EOF
    then
      err "state check failed after ${VALIDATE_TIMEOUT_STATE}s: want clusterStatus=HEALTHY with 127.0.10.11:5432=MASTER + 127.0.10.12:5433=SLAVE (tolerant of truncated rewrites; see $STATE)"
      rm -f "$st_file"
      return 1
    fi
    note "state: HEALTHY roles=$(cat "$st_file")"
  fi
  rm -f "$st_file"
  # Freshness: state must be newer than this launch (prepare deletes stale state).
  if [ "$STATE" -ot "$LAUNCH_FILE" ]; then
    err "stale $STATE (older than launch-id $launch_id); restart BFM on the current CONFIG"
    return 1
  fi

  # -- fresh BFM log evidence anchored by launch id (bounded polling).
  # healthy/pre-kill/rejoined floor (same lines as fast-env healthy): 5s
  # checkCluster (per-node Status + Cluster Status + active), 11s amIMasterBfm
  # no-pair discovery + 11s VIP check, 9s-initial autoconf clean, 30s pgpass
  # update. pairStatus starts "Active", so the no-pair/active lines prove real
  # discovery, not just startup.
  # down floor: INACCESSIBLE observation of pg1 + presence of the pg2 Status +
  # Cluster Status lines + active/no-pair discovery + autoconf clean + pgpass
  # + REAL attempt evidence (Failover Started / promote sent to / Master
  # Server start result / Error on Master Server start error:; INACCESSIBLE
  # is excluded from the attempt disjunction because it is already a
  # mandatory observation line, so it would pass with zero attempt) + the 11s
  # VIP check line (a MASTER is observed, so checkMasterVIPNetwork runs).
  local bfm_log="$LOGS/app.log" pat
  [ -f "$bfm_log" ] \
    || { err "BFM log $bfm_log absent (BFM must run with CWD=$run_canon so logging.file.name resolves here)"; return 1; }
  if [ "$bfm_log" -ot "$LAUNCH_FILE" ]; then
    err "stale BFM log $bfm_log (older than launch-id $launch_id); restart BFM on the current CONFIG"
    return 1
  fi
  if [ "$phase" = "down" ]; then
    for pat in \
      "Status of 127.0.10.11:5432 is INACCESSIBLE" \
      "Status of 127.0.10.12:5433 is " \
      "Cluster Status is " \
      "this is the active bfm pair" \
      "no bfm cluster pair" \
      "VIP Network Check result:" \
      "postgresql.auto.conf clean started on " \
      ".pgpass check & update started on server :"; do
      if poll_until "$VALIDATE_TIMEOUT_LOG" grep -qF "$pat" "$bfm_log" 2>/dev/null; then
        note "log: found '$pat'"
      else
        err "log evidence missing after ${VALIDATE_TIMEOUT_LOG}s: '$pat' not in $bfm_log (launch-id=$launch_id)"
        return 1
      fi
    done
    if grep -qE "Master Server start result|Error on Master Server start error:|Failover Started|promote sent to" "$bfm_log" 2>/dev/null; then
      note "log: attempt evidence present ($(grep -oE "Master Server start result|Error on Master Server start error:|Failover Started|promote sent to" "$bfm_log" 2>/dev/null | sort | uniq -c | tr '\n' ';'))"
    else
      err "log attempt evidence missing: none of 'Master Server start result' / 'Error on Master Server start error:' / 'Failover Started' / 'promote sent to' in $bfm_log"
      return 1
    fi
  else
    for pat in \
      "Cluster Status is " \
      "Status of 127.0.10.11:5432 is " \
      "Status of 127.0.10.12:5433 is " \
      "this is the active bfm pair" \
      "no bfm cluster pair" \
      "VIP Network Check result:" \
      "postgresql.auto.conf clean started on " \
      ".pgpass check & update started on server :"; do
      if poll_until "$VALIDATE_TIMEOUT_LOG" grep -qF "$pat" "$bfm_log" 2>/dev/null; then
        note "log: found '$pat'"
      else
        err "log evidence missing after ${VALIDATE_TIMEOUT_LOG}s: '$pat' not in $bfm_log (launch-id=$launch_id)"
        return 1
      fi
    done
    note "log: fixappname (6s) silent-by-design when app names healthy (no repair line expected; 30s pgpass proves the loop had opportunity)"
    note "log: checkUnavailable (7s) silent-by-design when no INACCESSIBLE (no rewind line expected; VIP/pgpass prove the loop had opportunity)"
  fi

  # -- VIP holder via the MiniPG agent (fail-closed, live-only proof).
  # down + rejoined phases: the seed-expected holder's /minipg/checkvip must
  # name it as holder.
  if [ "$phase" = "down" ] || [ "$phase" = "rejoined" ]; then
    local want_vip
    want_vip="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("vipHolder") or "")' "$seed")"
    [ "$want_vip" = "$PG2_IP" ] \
      || { err "seed $seed vipHolder='$want_vip' (want $PG2_IP for phase=$phase; stale fixtures? re-run '$0 prepare $scenario')"; return 1; }
    if poll_until "$VALIDATE_TIMEOUT_VIP" vip_on "$want_vip"; then
      note "vip: holder is $want_vip (agent /minipg/checkvip, seed-expected)"
    else
      err "vip: $want_vip not the holder after ${VALIDATE_TIMEOUT_VIP}s (agent /minipg/checkvip on $want_vip:$MINIPG_PORT must name $want_vip; body='$(minipg_body "$want_vip" "/minipg/checkvip" | redact || true)')"
      return 1
    fi
  fi

  # -- Redaction tripwire (fail-closed): credential-bearing forms must never
  # hit stored logs. The literal password is NOT scanned: with fixed test-only
  # creds (bfm/bfm) it is public and ubiquitous. What must never leak is the
  # secret-bearing form clients actually send: the HTTP-Basic base64 blob,
  # computed here from the live CONFIG values so any future creds stay covered.
  local f pg_blob mini_blob
  pg_blob="$(printf '%s:%s' "$pguser" "$pgpass" | base64 2>/dev/null | tr -d '\n')"
  mini_blob="$(printf '%s:%s' "$muser" "$mpass" | base64 2>/dev/null | tr -d '\n')"
  [ -n "$pg_blob" ] && [ -n "$mini_blob" ] \
    || { err "cannot derive credential blobs for leak scan (refusing)"; return 1; }
  for f in "$bfm_log" "$HELPER_LOG" "$LOGS"/bfm-helper.log; do
    [ -f "$f" ] || continue
    if grep -qF -- "$pg_blob" "$f" 2>/dev/null; then
      err "credential leak: Basic blob for server creds stored in $f (redaction failed)"
      return 1
    fi
    if [ "$mini_blob" != "$pg_blob" ] && grep -qF -- "$mini_blob" "$f" 2>/dev/null; then
      err "credential leak: Basic blob for minipg creds stored in $f (redaction failed)"
      return 1
    fi
  done

  log "validate-dependencies launch=$launch_id scenario=$scenario phase=$phase result=full-ok"
  note "validate-dependencies: OK (full, scenario=$scenario, phase=$phase, launch-id=$launch_id)"
  return 0
}

# --- status ----------------------------------------------------------------------
cmd_status() {
  guard_paths || return 1
  if [ ! -f "$CONFIG" ]; then note "live-env: not prepared (run '$0 prepare [healthy|kill-primary]' first)"; return 0; fi
  local launch_id="unknown"
  [ -f "$LAUNCH_FILE" ] && launch_id="$(cat "$LAUNCH_FILE")"
  note "launch-id=$launch_id scenario=$(cat "$SCENARIO_FILE" 2>/dev/null || echo unknown) project=$COMPOSE_PROJECT"
  note "server.pglist=$(config_val 'server\.pglist')"
  note "watcher.cluster-port=$(config_val 'watcher\.cluster-port') watcher.cluster-pair=$(config_val 'watcher\.cluster-pair') minipg.port=$(config_val 'minipg\.port')"
  local t addr port
  for t in $PG_TUPLES $MINIPG_TUPLES; do
    addr="${t%%:*}"; port="${t##*:}"
    if tuple_listening "$addr" "$port"; then
      note "tuple $addr:$port: LISTENING (pid=$(listener_pid "$addr" "$port" || true))"
    else
      note "tuple $addr:$port: free"
    fi
  done
  if tuple_listening "$BFM_IP" "$BFM_PORT"; then
    note "tuple $BFM_IP:$BFM_PORT: LISTENING (pid=$(listener_pid "$BFM_IP" "$BFM_PORT" || true))"
  else
    note "tuple $BFM_IP:$BFM_PORT: free"
  fi
  if docker_ok; then
    docker ps -a --filter "name=$PG1_CONTAINER" --filter "name=$PG2_CONTAINER" --format 'container {{.Names}}: {{.Status}}' 2>/dev/null || note "containers: (docker ps failed)"
  else
    note "containers: docker unavailable (daemon down or not installed)"
  fi
  if [ -f "$HELPER_BFM_PID" ]; then
    local p; p="$(cat "$HELPER_BFM_PID")"
    if kill -0 "$p" 2>/dev/null; then note "helper-owned BFM: pid=$p ALIVE"; else note "helper-owned BFM: pid=$p dead (stale)"; fi
  elif [ -f "$IDE_MARKER" ]; then
    note "BFM ownership: IDE-owned marker present"
  else
    note "BFM ownership: none recorded"
  fi
  if [ -f "$STATE" ]; then
    python3 -c "import json; d=json.load(open('$STATE')); print('state: clusterStatus=%s servers=%s' % (d.get('clusterStatus'), [(s.get('address'), s.get('databaseStatus')) for s in d.get('clusterServers', [])]))" 2>/dev/null \
      || note "state: present but transiently unreadable (BFM mid-rewrite; retry)"
  else
    note "state: absent (BFM writes $STATE on its check loop)"
  fi
  return 0
}

# --- logs ------------------------------------------------------------------------
cmd_logs() {
  guard_paths || return 1
  redact_refresh
  local n="${1:-100}"
  [[ "$n" =~ ^[0-9]+$ ]] || { err "logs takes a line count (got '$n')"; return 1; }
  local f found=0 c
  for f in "$HELPER_LOG" "$LOGS"/bfm-helper.log "$LOGS"/app.log; do
    [ -f "$f" ] || continue
    found=1
    note "== $f (last $n lines, redacted) =="
    tail -n "$n" "$f" 2>/dev/null | redact || true
  done
  if docker_ok; then
    for c in "$PG1_CONTAINER" "$PG2_CONTAINER"; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$c"; then
        found=1
        note "== docker logs $c (last $n lines, redacted) =="
        docker logs --tail "$n" "$c" 2>&1 | redact || true
      fi
    done
  else
    note "(docker unavailable; skipping container logs)"
  fi
  [ "$found" = "1" ] || note "no logs yet under $LOGS (run prepare/start first)"
  return 0
}

# --- stop ------------------------------------------------------------------------
# compose stop (containers kept, volumes kept) + kill helper-owned BFM only.
# Never touches IDE-owned BFM.
cmd_stop() {
  refuse_overrides || return 1
  guard_paths || return 1
  check_owner stop || return 1
  if [ -f "$COMPOSE_STAGED" ] && docker_ok; then
    if compose stop 2>&1 | redact >>"$HELPER_LOG" 2>/dev/null; then
      note "stopped compose project $COMPOSE_PROJECT (containers kept, volumes kept)"
    else
      err "docker compose stop failed (see $HELPER_LOG)"
      return 1
    fi
  else
    note "stop: compose skipped (no staged compose.yaml or docker unavailable)"
  fi
  local p stopping=0
  for f in "$HELPER_BFM_PID" "$PIDS_FILE"; do
    [ -f "$f" ] || continue
    while read -r p; do
      [ -n "$p" ] || continue
      if kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null || true
        note "stopped pid=$p (from $f)"
        stopping=1
      fi
    done <"$f"
    rm -f "$f"
  done
  [ "$stopping" = "0" ] && note "stop: no helper-owned processes running"
  if [ -f "$IDE_MARKER" ]; then
    note "stop: IDE-owned BFM marker present - leaving IDE BFM alone"
  fi
  log "stop done"
  return 0
}

# --- reset -------------------------------------------------------------------------
cmd_reset() {
  refuse_overrides || return 1
  guard_paths || return 1
  [ -e "$LIVE_DIR" ] || { note "reset: nothing to do ($LIVE_DIR absent)"; return 0; }
  if [ -f "$IDE_MARKER" ]; then
    err "refusing reset: IDE-owned BFM is active ($IDE_MARKER). Stop the IDE/F5 session and remove the marker first."
    return 1
  fi
  if tuple_listening "$BFM_IP" "$BFM_PORT"; then
    err "refusing reset: BFM tuple $BFM_TUPLE is still occupied. Stop that BFM first."
    return 1
  fi
  if [ -f "$PIDS_FILE" ] && pids_alive "$PIDS_FILE"; then
    err "refusing reset: helper-owned processes still running (run '$0 stop' first)"
    return 1
  fi
  if [ -f "$HELPER_BFM_PID" ]; then
    local p; p="$(cat "$HELPER_BFM_PID")"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      err "refusing reset: helper-owned BFM pid=$p still running (run '$0 stop' first)"
      return 1
    fi
  fi
  check_owner reset || return 1
  # Volumes are docker named volumes prefixed bfm-live-: down -v removes them.
  if [ -f "$COMPOSE_STAGED" ]; then
    if docker_ok; then
      if compose down -v 2>&1 | redact >>"$HELPER_LOG" 2>/dev/null; then
        note "reset: compose down -v done (volumes removed)"
      else
        err "refusing reset: docker compose down -v failed (volumes may leak; see $HELPER_LOG)"
        return 1
      fi
    else
      note "reset: docker unavailable; skipping compose down -v (no daemon to hold volumes)"
    fi
  else
    note "reset: no staged compose.yaml; skipping compose down -v"
  fi
  rm -rf -- "$LIVE_DIR"
  note "reset: removed $LIVE_DIR (repo-root bfm_status.json, _work-tmp/local/ and _work-tmp/fast-env/ untouched)"
  return 0
}

# --- start / validate (helper-owned BFM wrappers) ----------------------------------
cmd_start() {
  refuse_overrides || return 1
  guard_paths || return 1
  cmd_start_dependencies || return 1
  if [ -f "$HELPER_BFM_PID" ] && pids_alive "$HELPER_BFM_PID"; then
    err "helper-owned BFM already running (pid=$(cat "$HELPER_BFM_PID"))"
    return 1
  fi
  if tuple_listening "$BFM_IP" "$BFM_PORT"; then
    err "BFM tuple $BFM_TUPLE is occupied (IDE-owned BFM? use validate-dependencies for that case)"
    return 1
  fi
  local jar
  jar="$(ls "$REPO_ROOT"/app/target/bfm-app-*.jar 2>/dev/null | head -n 1 || true)"
  [ -n "$jar" ] || { err "no built jar at app/target/bfm-app-*.jar (hint: just build)"; return 1; }
  mkdir -p "$LOGS"
  local p
  p="$(cd "$RUN_DIR" && launch_bg_redacted "$LOGS/bfm-helper.log" no_proxy_env nohup java -Dspring.config.location="file:$CONFIG" -jar "$jar")"
  printf '%s\n' "$p" >"$HELPER_BFM_PID"
  # `start` always launches BFM, so it always appends its pgid to the owner
  # set (idempotent when start-dependencies ran in the same pgid).
  owner_append
  log "start helper-owned BFM pid=$p jar=$jar"
  note "helper-owned BFM starting pid=$p (logs: $LOGS/bfm-helper.log, $LOGS/app.log)"
  return 0
}

cmd_validate() {
  refuse_overrides || return 1
  guard_paths || return 1
  if [ ! -f "$HELPER_BFM_PID" ] || ! pids_alive "$HELPER_BFM_PID"; then
    err "no helper-owned BFM running (start one via '$0 start'; for IDE-owned BFM use '$0 validate-dependencies')"
    return 1
  fi
  cmd_validate_dependencies
}

# --- kill-primary / rejoin (kill-primary scenario drivers) ---------------------------
# kill-primary: docker stop bfm-live-pg1, bounded wait for TCP DOWN (BFM owns
# the failover: promotes pg2, moves VIP). rejoin: docker start bfm-live-pg1,
# bounded wait for TCP UP (BFM rejoins it as replica via rewind/rebase).
require_kill_scenario() { # require_kill_scenario <op>
  local op="$1" scenario
  scenario="$(current_scenario)"
  [ "$scenario" = "kill-primary" ] \
    || { err "'$op' requires scenario 'kill-primary' (prepared as '$scenario'; run '$0 reset' + '$0 prepare kill-primary' to switch)"; return 1; }
  [ -f "$CONFIG" ] || { err "not prepared (run '$0 prepare kill-primary' first)"; return 1; }
  docker_ok || { err "docker daemon unreachable ('$op' needs it)"; return 1; }
  return 0
}

cmd_kill_primary() {
  refuse_overrides || return 1
  guard_paths || return 1
  require_kill_scenario "kill-primary" || return 1
  redact_refresh
  if ! tcp_probe "$PG1_IP" "$PG1_PORT"; then
    note "kill-primary: $PG1_CONTAINER already DOWN (nothing to do)"
    return 0
  fi
  docker stop "$PG1_CONTAINER" >/dev/null 2>&1 \
    || { err "docker stop $PG1_CONTAINER failed"; return 1; }
  # Bounded wait for TCP DOWN (explicit loop: the probe must FAIL).
  local end=$((SECONDS + KILL_TIMEOUT_DOWN))
  while (( SECONDS < end )) && tcp_probe "$PG1_IP" "$PG1_PORT"; do sleep 0.5; done
  if tcp_probe "$PG1_IP" "$PG1_PORT"; then
    err "kill-primary: $PG1_IP:$PG1_PORT still UP after ${KILL_TIMEOUT_DOWN}s (docker stop $PG1_CONTAINER did not take effect?)"
    return 1
  fi
  log "kill-primary $PG1_CONTAINER stopped (TCP DOWN)"
  note "kill-primary: $PG1_CONTAINER stopped (pg $PG1_IP:$PG1_PORT DOWN; BFM owns the failover)"
  return 0
}

cmd_rejoin() {
  refuse_overrides || return 1
  guard_paths || return 1
  require_kill_scenario "rejoin" || return 1
  redact_refresh
  if tcp_probe "$PG1_IP" "$PG1_PORT"; then
    note "rejoin: $PG1_CONTAINER already UP (nothing to do; BFM rejoins it)"
    return 0
  fi
  docker start "$PG1_CONTAINER" >/dev/null 2>&1 \
    || { err "docker start $PG1_CONTAINER failed"; return 1; }
  if ! poll_until "$REJOIN_TIMEOUT_UP" tcp_probe "$PG1_IP" "$PG1_PORT"; then
    err "rejoin: $PG1_IP:$PG1_PORT still DOWN after ${REJOIN_TIMEOUT_UP}s (docker start $PG1_CONTAINER did not take effect?)"
    return 1
  fi
  # SQL readiness: PG must answer queries, not just TCP (crash-recovery window).
  if poll_until "$REJOIN_TIMEOUT_SQL" pg_ready "$PG1_IP" "$PG1_PORT"; then
    log "rejoin $PG1_CONTAINER started (TCP UP, SQL ready)"
    note "rejoin: $PG1_CONTAINER started (pg $PG1_IP:$PG1_PORT UP + SQL ready; BFM rejoins it as replica)"
    return 0
  fi
  err "rejoin: $PG1_IP:$PG1_PORT TCP UP but answered no SQL after ${REJOIN_TIMEOUT_SQL}s (still in crash recovery?)"
  return 1
}

# --- dispatch ----------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

  prepare [healthy|kill-primary]   render config + stage compose.yaml + write launch-id/owner/scenario (docker-independent)
  start-dependencies      compose up -d --build, then bounded waits for PG TCP + MiniPG HTTP
  validate-dependencies   bounded-poll validation (deps + live SQL + BFM evidence REQUIRED; fails when BFM absent)
  status                  show tuples, containers, pids, config, state summary (read-only)
  logs [N]                tail redacted logs incl. docker logs --tail (default 100 lines)
  stop                    compose stop + stop helper-owned BFM only (never IDE-owned BFM)
  reset                   compose down -v + delete _work-tmp/live-env/ (refuses while IDE BFM active)
  start                   start-dependencies + helper-owned BFM from built jar
  validate                validate-dependencies for helper-owned BFM (refuses otherwise)
  kill-primary            docker stop bfm-live-pg1, bounded wait for TCP DOWN (kill-primary scenario only)
  rejoin                  docker start bfm-live-pg1, bounded wait for TCP UP (kill-primary scenario only)
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    prepare)               shift; cmd_prepare "${1:-healthy}" ;;
    start-dependencies)    shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_start_dependencies ;;
    validate-dependencies) shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_validate_dependencies ;;
    status)                shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_status ;;
    logs)                  shift; [ $# -le 1 ] || { usage >&2; return 2; }; cmd_logs "${1:-100}" ;;
    stop)                  shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_stop ;;
    reset)                 shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_reset ;;
    start)                 shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_start ;;
    validate)              shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_validate ;;
    kill-primary)          shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_kill_primary ;;
    rejoin)                shift; [ $# -eq 0 ] || { usage >&2; return 2; }; cmd_rejoin ;;
    -h|--help|help|"")     usage; return 0 ;;
    *) err "unknown command '$cmd'"; usage >&2; return 2 ;;
  esac
}

main "$@"
