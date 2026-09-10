#!/usr/bin/env bash
# BFM fast environment helper (milestone 1).
#
# Primary loop (IDE-owned BFM):
#   fast-env.sh prepare healthy -> fast-env.sh start-dependencies
#     -> F5 "BFM - fast environment" -> fast-env.sh validate-dependencies
# Secondary (helper-owned BFM):
#   fast-env.sh start -> fast-env.sh validate
# Inspect/teardown: status, logs [N], stop, reset.
#
# Fixed topology (docs/decisions/0002):
#   BFM                127.0.0.1:9995   (watcher.cluster-port, server.address)
#   PG node 1          127.0.10.11:5432 (PG-wire stub)
#   PG node 2          127.0.10.12:5433 (PG-wire stub)
#   MiniPG per node    127.0.10.11:7779 + 127.0.10.12:7779 (WireMock, same port)
#   Peer BFM           no-pair
#
# Layout (all generated, git-ignored, disposable):
#   _work-tmp/fast-env/application.properties   spring.config.location target
#   _work-tmp/fast-env/run/bfm_status.json      BFM CWD + state (PrintWriter-truncated: readers retry)
#   _work-tmp/fast-env/logs/                    pre-storage-redacted helper/stub/BFM logs
#   _work-tmp/fast-env/fixtures/<scenario>/     copy of tools/fast-env/fixtures/<scenario>/
#   _work-tmp/fast-env/wiremock-<ip>/           staged WireMock roots (mappings/ + __files/)
#   _work-tmp/fast-env/.(launch-id|owner|scenario|pids|helper-bfm.pid)
#   _work-tmp/fast-env/.ide-bfm-active          IDE-owned BFM marker (F5 flow creates it;
#                                               this helper only respects it, never creates it)
#   _work-tmp/fast-env-tool-cache/              pinned WireMock jar (survives `reset`)
#
# Fast-env credentials are fixed test-only bfm/bfm (loopback-only, same as
# bfm4patroni's fast env). `prepare` copies dev/fast-env/application.properties
# (read-only template) verbatim. An inline fallback is used only when the
# template is absent and carries the same loopback topology + fixed creds.
#
# Stub entry points:
#   tools/fast-env/pgwire-stub.py --host/--port/--fixture (one process per node)
#   tools/fast-env/fixtures/<scenario>/   WireMock mappings + pg-wire rows
# WireMock artifact: pinned + SHA-256-verified standalone jar in the tool cache
# (mirrors bfm4patroni local-regression pin). `prepare` downloads/verifies it;
# `start-dependencies` adopts already-listening tuples, launches pgwire stubs
# with the documented CLI when their tuples are free, and launches per-IP
# WireMock JVMs (--bind-address/--port/--root-dir + no-proxy/journal flags)
# from the staged fixture mappings. Anything else fails clearly (fail-closed).
#
# validate-dependencies semantics (bounded polling everywhere, no blind sleeps):
# stub-tuple liveness + fixture bytes are mandatory AND BFM evidence is
# mandatory (no deps-only green): the IDE/helper-owned BFM must be listening on
# 127.0.0.1:9995 with /proc-proven config/CWD identity, fresh launch-id-anchored
# logs covering the healthy background-task floor (5s checkCluster incl. per-node
# "Status of" + "Cluster Status is " + "this is the active bfm pair", 11s
# amIMasterBfm "no bfm cluster pair" + 11s VIP "VIP Network Check result:",
# 9s-initial "postgresql.auto.conf clean started on ", 30s ".pgpass check &
# update started on server :"; 6s fixappname + 7s checkUnavailable are
# silent-by-design when healthy so their opportunity is proven via the longer
# intervals, not a positive line), bfm_status.json HEALTHY + MASTER/SLAVE roles
# with retry-on-truncated-write, and real active/no-pair discovery (pairStatus
# starts "Active", so the no-pair/active lines are required, not just startup).
# Stored-log redaction is fail-closed (secrets in stored logs => fail).
#
# Safety (bfm4patroni parity, BFM-concrete): explicit 127.0.0.1 bind, tuple-aware
# occupancy incl. wildcard listeners, proxy bypass on every probe, pre-storage
# log redaction (fail-closed), canonical-path + symlink refusal, PID/group
# ownership enforcement (OWNER pgid checked on stop/reset, never just stored),
# reset refusal while IDE-owned BFM is active, refusal of external
# spring/JVM/MAVEN overrides and of the BFM deployment path
# (/etc/bfm/bfmwatcher/application.properties). Never touches repo-root
# bfm_status.json or _work-tmp/local/.
set -euo pipefail

# --- fixed topology ------------------------------------------------------------
BFM_IP="127.0.0.1"
BFM_PORT="9995"
PG1_IP="127.0.10.11"; PG1_PORT="5432"
PG2_IP="127.0.10.12"; PG2_PORT="5433"
MINIPG_PORT="7779"
# addr:port tuples owned by this environment (never bare ports)
STUB_TUPLES="$PG1_IP:$PG1_PORT $PG2_IP:$PG2_PORT $PG1_IP:$MINIPG_PORT $PG2_IP:$MINIPG_PORT"
BFM_TUPLE="$BFM_IP:$BFM_PORT"

# External overrides that would silently change JVM/Spring/Maven behaviour
# (SPRING_CONFIG_LOCATION gets its own message: it also covers the BFM
# deployment path /etc/bfm/bfmwatcher/application.properties).
REFUSED_ENV="_JAVA_OPTIONS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS JAVA_OPTS MAVEN_OPTS MAVEN_ARGS SPRING_PROFILES_ACTIVE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLS_DIR="$REPO_ROOT/tools/fast-env"
FAST_DIR="$REPO_ROOT/_work-tmp/fast-env"
CONFIG="$FAST_DIR/application.properties"
RUN_DIR="$FAST_DIR/run"
STATE="$RUN_DIR/bfm_status.json"
LOGS="$FAST_DIR/logs"
HELPER_LOG="$LOGS/fast-env.log"
OWNER_FILE="$FAST_DIR/.owner"
LAUNCH_FILE="$FAST_DIR/.launch-id"
SCENARIO_FILE="$FAST_DIR/.scenario"
PIDS_FILE="$FAST_DIR/.pids"
HELPER_BFM_PID="$FAST_DIR/.helper-bfm.pid"
IDE_MARKER="$FAST_DIR/.ide-bfm-active"

# Pinned MiniPG artifact (mirrors bfm4patroni tools/local-regression pin).
# Cache lives OUTSIDE the run dir so `reset` (rm -rf FAST_DIR) keeps it.
WIREMOCK_VERSION="3.9.1"
WIREMOCK_SHA256="723a880d50d3b0a145af0df07e578c2cb85e77feb2231e6991c9a1366926912c"
WIREMOCK_URL="https://repo1.maven.org/maven2/org/wiremock/wiremock-standalone/${WIREMOCK_VERSION}/wiremock-standalone-${WIREMOCK_VERSION}.jar"
TOOL_CACHE="${BFM_FAST_ENV_TOOL_CACHE:-$REPO_ROOT/_work-tmp/fast-env-tool-cache}"
WIREMOCK_JAR="$TOOL_CACHE/wiremock-standalone-${WIREMOCK_VERSION}.jar"

VALIDATE_TIMEOUT_STUBS=15
VALIDATE_TIMEOUT_BFM_HTTP=90
VALIDATE_TIMEOUT_STATE=90
VALIDATE_TIMEOUT_LOG=90

# --- small utils ---------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }

# Pre-storage redaction: strip passwords / Basic creds before anything hits disk.
# Static patterns live in REDACT_STATIC; redact_refresh appends the literal
# configured secrets from CONFIG — except the fixed public test-only value
# "bfm" (loopback-only fast env, same convention as bfm4patroni): redacting
# that literal would mangle every innocent mention, and BFM's own file log
# bypasses this pipeline anyway. Its only secret-bearing form, the Basic
# blob YmZtOmJmbQ== (bfm:bfm), is covered by a static rule below.
# redact_refresh runs in normal flow only.
# PROCsub SAFETY: redact()'s body MUST stay a single simple command. A compound
# body (if/list/||) in a >( ) target combined with a $( ) capture hangs bash:
# the extra fork level inherits the capture pipe's write end, so $( ) never
# completes. Verified by bisection; do not "improve" this function.
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
      # Skip the fixed public test-only "bfm": redacting that literal would
      # mangle innocent log text; its secret-bearing Basic blob is covered
      # by the static rule. Any other configured secret is still redacted.
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

# All disposable state must live at exactly _work-tmp/fast-env (canonical, no
# symlinks, never /etc/bfm, never _work-tmp/local, never repo root state).
# The tool cache is a sibling (_work-tmp/fast-env-tool-cache) so `reset`
# (rm -rf FAST_DIR) keeps the pinned jar; it gets the same canonical/symlink
# discipline and must stay under _work-tmp.
guard_paths() {
  local canon_fast canon_repo canon_cache
  canon_fast="$(canonical "$FAST_DIR")"
  canon_repo="$(canonical "$REPO_ROOT")"
  canon_cache="$(canonical "$TOOL_CACHE")"
  [ "$canon_fast" = "$canon_repo/_work-tmp/fast-env" ] \
    || { err "refusing unexpected fast-env dir: $canon_fast"; return 1; }
  refuse_symlink "$canon_fast" || return 1
  [ -e "$RUN_DIR" ] && refuse_symlink "$(canonical "$RUN_DIR")" || true
  case "$canon_fast" in
    /etc/bfm/*|/_work-tmp/local*|"$canon_repo/_work-tmp/local"*) err "refusing deployment/local path: $canon_fast"; return 1;;
  esac
  case "$canon_cache" in
    "$canon_repo/_work-tmp/fast-env-tool-cache"|"$canon_repo/_work-tmp/fast-env-tool-cache/"*) ;;
    *) err "refusing unexpected tool-cache dir: $canon_cache (want $canon_repo/_work-tmp/fast-env-tool-cache)"; return 1;;
  esac
  [ -e "$TOOL_CACHE" ] && refuse_symlink "$canon_cache" || true
  case "$canon_cache" in
    /etc/bfm/*|"$canon_repo/_work-tmp/local"*) err "refusing deployment/local tool-cache path: $canon_cache"; return 1;;
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
      err "refusing external $v='$val' (unset it for fast-env runs, e.g. env -u $v)"
      return 1
    fi
  done
  case "${PWD:-}" in
    /etc/bfm/*) err "refusing to run from BFM deployment path: $PWD"; return 1;;
  esac
  return 0
}

# --- pinned WireMock artifact (tool cache, survives reset) -----------------------
# Mirrors bfm4patroni tools/local-regression download/verify mechanism.
verify_wiremock_jar() {
  [ -f "$WIREMOCK_JAR" ] \
    || { err "WireMock $WIREMOCK_VERSION not prepared at $WIREMOCK_JAR (run '$0 prepare healthy' first)"; return 1; }
  local got
  got="$(sha256sum "$WIREMOCK_JAR" 2>/dev/null | awk '{ print $1 }')"
  [ "$got" = "$WIREMOCK_SHA256" ] \
    || { err "prepared WireMock artifact failed its checksum ($WIREMOCK_JAR; want SHA-256 $WIREMOCK_SHA256)"; return 1; }
  return 0
}

download_wiremock() {
  mkdir -p "$TOOL_CACHE"
  if [ -f "$WIREMOCK_JAR" ]; then
    verify_wiremock_jar || return 1
    note "wiremock: CACHED $WIREMOCK_JAR ($WIREMOCK_VERSION, sha256 OK)"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { err "curl is required to download WireMock $WIREMOCK_VERSION"; return 1; }
  command -v sha256sum >/dev/null 2>&1 || { err "sha256sum is required to verify WireMock $WIREMOCK_VERSION"; return 1; }
  local tmp
  tmp="$(mktemp "$TOOL_CACHE/.wiremock-download.XXXXXX")" \
    || { err "cannot stage WireMock download in $TOOL_CACHE"; return 1; }
  note "wiremock: downloading $WIREMOCK_VERSION ..."
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --retry 3 --output "$tmp" "$WIREMOCK_URL"; then
    rm -f -- "$tmp"
    err "WireMock $WIREMOCK_VERSION download failed ($WIREMOCK_URL)"
    return 1
  fi
  if [ "$(sha256sum "$tmp" | awk '{ print $1 }')" != "$WIREMOCK_SHA256" ]; then
    rm -f -- "$tmp"
    err "downloaded WireMock $WIREMOCK_VERSION failed its checksum (want $WIREMOCK_SHA256)"
    return 1
  fi
  mv -- "$tmp" "$WIREMOCK_JAR"
  chmod 600 "$WIREMOCK_JAR"
  note "wiremock: READY $WIREMOCK_JAR ($WIREMOCK_VERSION, sha256 OK)"
  return 0
}

# --- PID/group ownership ----------------------------------------------------------
# OWNER_FILE is written by `prepare` (dir + pid + pgid + date). stop/reset must
# CHECK the recorded pgid against live truth, never just trust the dir line.
# Fail-closed: refuse to kill/delete when the group cannot be proven, so a
# foreign or tampered PIDS file can never cause us to kill foreign PIDs.
check_owner() { # check_owner <op>
  local op="${1:-stop}"
  [ -f "$OWNER_FILE" ] || return 0
  local owner_dir owner_pid owner_pgid
  owner_dir="$(grep -E '^dir=' "$OWNER_FILE" 2>/dev/null | cut -d= -f2-)"
  owner_pid="$(grep -E '^pid=' "$OWNER_FILE" 2>/dev/null | cut -d= -f2-)"
  owner_pgid="$(grep -E '^pgid=' "$OWNER_FILE" 2>/dev/null | cut -d= -f2-)"
  [ -n "$owner_dir" ] \
    || { err "ownership file $OWNER_FILE missing dir (refusing $op)"; return 1; }
  [ "$owner_dir" = "$(canonical "$FAST_DIR")" ] \
    || { err "ownership mismatch ($OWNER_FILE points at '$owner_dir'); refusing to $op"; return 1; }
  case "$owner_pid" in ''|*[!0-9]*) err "ownership file $OWNER_FILE has invalid pid '$owner_pid' (refusing $op)"; return 1;; esac
  case "$owner_pgid" in ''|*[!0-9]*) err "ownership file $OWNER_FILE has invalid pgid '$owner_pgid' (refusing $op)"; return 1;; esac
  # When the preparing pid is still alive, its live pgid must match the record.
  if kill -0 "$owner_pid" 2>/dev/null; then
    local live_pgid
    live_pgid="$(ps -o pgid= -p "$owner_pid" 2>/dev/null | tr -d ' ')"
    [ -n "$live_pgid" ] \
      || { err "cannot prove owner pid=$owner_pid group (refusing $op)"; return 1; }
    [ "$live_pgid" = "$owner_pgid" ] \
      || { err "ownership group mismatch (owner pid=$owner_pid live pgid=$live_pgid != recorded pgid=$owner_pgid; refusing $op)"; return 1; }
  fi
  # Helper-owned pids must belong to the recorded group while alive.
  local f p actual
  for f in "$PIDS_FILE" "$HELPER_BFM_PID"; do
    [ -f "$f" ] || continue
    while read -r p; do
      [ -n "$p" ] || continue
      kill -0 "$p" 2>/dev/null || continue
      actual="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"
      [ -n "$actual" ] \
        || { err "cannot prove helper pid=$p group (refusing $op)"; return 1; }
      [ "$actual" = "$owner_pgid" ] \
        || { err "helper pid=$p pgid=$actual outside owner pgid=$owner_pgid (refusing $op; foreign pid?)"; return 1; }
    done <"$f"
  done
  return 0
}

# --- tuple-aware occupancy ------------------------------------------------------
# tuple_listening <ip> <port>: true when anything (incl. 0.0.0.0 / :: wildcard)
# holds the exact addr:port tuple. Prefers ss, falls back to /proc/net/tcp*.
tuple_listening() {
  local ip="$1" port="$2" line
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if printf '%s' "$line" | awk -v IP="$ip" -v P="$port" '
        { f=$4; sub(/%[^: ]*:/, ":", f); n=split(f,a,":"); p=a[n];
          addr=f; sub(/:[^:]*$/, "", addr); gsub(/^\[|\]$/, "", addr);
          if (p==P && (addr==IP || addr=="0.0.0.0" || addr=="*" || addr=="::")) exit 0; exit 1 }'; then
        return 0
      fi
    done < <(ss -tlnH 2>/dev/null || true)
    return 1
  fi
  # Fallback: /proc/net/tcp + tcp6, little-endian hex, LISTEN == 0A.
  local f hex_ip hex_port
  hex_port=$(printf '%04X' "$port")
  hex_ip=$(printf '%s' "$ip" | awk -F. '{printf "%02X%02X%02X%02X",$4,$3,$2,$1}')
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    if awk -v H="$hex_ip" -v P="$hex_port" 'NR>1 && $4=="0A" {
        split($2,a,":"); ip=a[1]; port=a[2];
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

# Render CONFIG from the dev/fast-env template (or the inline fallback).
# Credentials are fixed test-only bfm/bfm (loopback-only); no substitution.
render_config() { # render_config <launch> <scenario>
  local launch_id="$1" scenario="$2"
  local template="$REPO_ROOT/dev/fast-env/application.properties"
  if [ -f "$template" ]; then
    cp "$template" "$CONFIG"
    note "config: TEMPLATE $template"
  else
    note "config: WARN template $template absent; using inline fallback"
    cat >"$CONFIG" <<EOF
# BFM fast-environment config (INLINE FALLBACK - template absent).
app.bfm-hc-clustername          = BFMCluster
app.custom-logo-path            =
server.address                  = 127.0.0.1
server.pguser                   = bfm
server.pgpassword               = bfm
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
  for tok in '@@FAST_PGUSER@@' '@@FAST_PGPASSWORD@@' '@@FAST_MINIPG_USER@@' '@@FAST_MINIPG_PASSWORD@@'; do
    if grep -qF "$tok" "$CONFIG"; then
      err "unsubstituted token $tok left in $CONFIG (template/contract drift)"
      return 1
    fi
  done
  # Prepend the launch header without touching the rendered body.
  local tmp; tmp="$(mktemp)"
  {
    printf '# GENERATED by tools/fast-env/fast-env.sh (DO NOT edit, DO NOT use in production).\n'
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

# --- prepare ---------------------------------------------------------------------
cmd_prepare() {
  local scenario="${1:-healthy}"
  refuse_overrides || return 1
  guard_paths || return 1
  [ "$scenario" = "healthy" ] \
    || { err "unknown scenario '$scenario' (v1 supports only 'healthy')"; return 1; }
  if [ -f "$IDE_MARKER" ]; then
    err "IDE-owned BFM is active ($IDE_MARKER); stop it before re-preparing"
    return 1
  fi
  if [ -f "$PIDS_FILE" ] && pids_alive "$PIDS_FILE"; then
    err "helper-owned processes are running (run '$0 stop' first)"
    return 1
  fi
  if tuple_listening "$BFM_IP" "$BFM_PORT"; then
    err "BFM tuple $BFM_TUPLE is occupied; stop that BFM before re-preparing"
    return 1
  fi

  mkdir -p "$RUN_DIR" "$LOGS"
  local launch_id="fast-$(date +%s)-$$-$RANDOM"

  render_config "$launch_id" "$scenario" || return 1
  redact_refresh
  printf '%s\n' "$launch_id" >"$LAUNCH_FILE"
  printf '%s\n' "$scenario" >"$SCENARIO_FILE"
  printf 'dir=%s\npid=%s\npgid=%s\ndate=%s\n' \
    "$(canonical "$FAST_DIR")" "$$" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" "$(date -u '+%FT%TZ')" >"$OWNER_FILE"
  chmod 600 "$OWNER_FILE" "$LAUNCH_FILE" "$SCENARIO_FILE" 2>/dev/null || true

  # Pinned MiniPG artifact: download + SHA-256-verify into the tool cache
  # (outside the run dir so `reset` keeps it). Fail-closed on download/verify.
  download_wiremock || return 1

  # Fixtures: copy fixture sources verbatim (fixed bfm/bfm creds, no tokens).
  local src="$TOOLS_DIR/fixtures/$scenario" dst="$FAST_DIR/fixtures/$scenario"
  mkdir -p "$dst"
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
    cp -r "$src/." "$dst/"
    note "fixtures: COPY $src -> $dst"
  else
    note "fixtures: WARN source $src missing/empty (fixture worker owns it); left $dst empty"
  fi
  # Stale disposable state from a previous run must not poison validation.
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
# Per tuple: adopt when already listening, else launch helper-owned processes.
# pgwire-stub.py --host/--port/--fixture; per-IP WireMock JVMs from the pinned
# tool-cache jar with staged fixture mappings. Missing pieces fail clearly.
PGWIRE_STUB="$TOOLS_DIR/pgwire-stub.py"
PGWIRE_FIX1="pgwire-node1.json"
PGWIRE_FIX2="pgwire-node2.json"

ensure_pgwire() { # ensure_pgwire <ip> <port> <fixture-name>
  local ip="$1" port="$2" fixture="$3"
  if tuple_listening "$ip" "$port"; then
    note "stub tuple $ip:$port: LISTENING (externally owned; adopted)"
    return 0
  fi
  [ -f "$PGWIRE_STUB" ] \
    || { err "stub tuple $ip:$port is free and $PGWIRE_STUB is missing"; return 1; }
  local fix="$FAST_DIR/fixtures/healthy/$fixture"
  [ -f "$fix" ] || fix="$TOOLS_DIR/fixtures/healthy/$fixture"
  [ -f "$fix" ] \
    || { err "stub tuple $ip:$port is free and pgwire fixture $fixture is missing (run '$0 prepare healthy' first)"; return 1; }
  local logf="$LOGS/stub-pgwire-$ip-$port.log" pid
  : >"$logf"
  chmod 600 "$logf" 2>/dev/null || true
  pid="$(launch_bg_redacted "$logf" no_proxy_env python3 -u "$PGWIRE_STUB" --host "$ip" --port "$port" --fixture "$fix")"
  echo "$pid" >>"$PIDS_FILE"
  if poll_until 15 tcp_probe "$ip" "$port"; then
    if kill -0 "$pid" 2>/dev/null; then
      note "stub tuple $ip:$port: STARTED helper-owned pid=$pid"
      log "start-dependencies pgwire $ip:$port pid=$pid fixture=$fixture"
      return 0
    fi
  fi
  err "pgwire stub for $ip:$port failed to come up (pid=$pid; see $logf)"
  return 1
}

ensure_minipg() { # ensure_minipg <ip> <node-dir-name>
  local ip="$1" nodedir="$2"
  if tuple_listening "$ip" "$MINIPG_PORT"; then
    note "stub tuple $ip:$MINIPG_PORT: LISTENING (externally owned; adopted)"
    return 0
  fi
  verify_wiremock_jar || return 1
  command -v java >/dev/null 2>&1 \
    || { err "stub tuple $ip:$MINIPG_PORT is free but java is unavailable (WireMock needs Java 21)"; return 1; }
  local srcdir="$FAST_DIR/fixtures/healthy/$nodedir"
  [ -d "$srcdir" ] \
    || { err "stub tuple $ip:$MINIPG_PORT is free and mappings source $nodedir is missing (run '$0 prepare healthy' first)"; return 1; }
  [ -n "$(ls -A "$srcdir" 2>/dev/null)" ] \
    || { err "stub tuple $ip:$MINIPG_PORT is free and mappings source $srcdir is empty (run '$0 prepare healthy' first)"; return 1; }
  # Stage a WireMock root: fixtures are flat <op>.json files, WireMock loads
  # <root>/mappings/*.json (+ __files/). Staging keeps fixture contents intact.
  local wm_root="$FAST_DIR/wiremock-$ip"
  rm -rf -- "$wm_root"
  mkdir -p "$wm_root/mappings" "$wm_root/__files"
  cp -f "$srcdir"/*.json "$wm_root/mappings/" 2>/dev/null \
    || { err "cannot stage WireMock mappings from $srcdir"; return 1; }
  [ -n "$(ls -A "$wm_root/mappings" 2>/dev/null)" ] \
    || { err "no WireMock mappings staged from $srcdir"; return 1; }
  local logf="$LOGS/stub-minipg-$ip-$MINIPG_PORT.log" pid
  : >"$logf"
  chmod 600 "$logf" 2>/dev/null || true
  pid="$(launch_bg_redacted "$logf" no_proxy_env java -jar "$WIREMOCK_JAR" --bind-address "$ip" --port "$MINIPG_PORT" --root-dir "$wm_root" --disable-banner --disable-extensions-scanning --disable-request-logging --no-request-journal --proxy-pass-through=false)"
  echo "$pid" >>"$PIDS_FILE"
  if poll_until 30 tcp_probe "$ip" "$MINIPG_PORT" && kill -0 "$pid" 2>/dev/null; then
    note "stub tuple $ip:$MINIPG_PORT: STARTED helper-owned pid=$pid (WireMock $WIREMOCK_VERSION)"
    log "start-dependencies minipg $ip:$MINIPG_PORT pid=$pid rootdir=$nodedir"
    return 0
  fi
  err "MiniPG WireMock for $ip:$MINIPG_PORT failed to come up (pid=$pid; see $logf)"
  return 1
}

cmd_start_dependencies() {
  refuse_overrides || return 1
  guard_paths || return 1
  [ -f "$CONFIG" ] || { err "not prepared (run '$0 prepare healthy' first)"; return 1; }
  redact_refresh
  mkdir -p "$LOGS"
  : >>"$PIDS_FILE"

  local rc=0
  ensure_pgwire "$PG1_IP" "$PG1_PORT" "$PGWIRE_FIX1" || rc=1
  ensure_pgwire "$PG2_IP" "$PG2_PORT" "$PGWIRE_FIX2" || rc=1
  ensure_minipg "$PG1_IP" "minipg-node1" || rc=1
  ensure_minipg "$PG2_IP" "minipg-node2" || rc=1
  if [ "$rc" != "0" ]; then
    err "start-dependencies: INCOMPLETE - provide the missing pieces above, then re-run (listening tuples are adopted; 'stop' tears down helper-owned stubs)"
    return 1
  fi
  log "start-dependencies: all stub tuples listening"
  note "start-dependencies: all stub tuples listening"
  return 0
}

# --- validate-dependencies -------------------------------------------------------
# BFM evidence is MANDATORY (no deps-only green): stubs + fixtures + BFM
# listener with /proc-proven config/CWD identity + fresh launch-id-anchored
# logs for the healthy background-task floor + HEALTHY state. Fails when the
# IDE/helper-owned BFM is absent or identity cannot be proven.
cmd_validate_dependencies() {
  refuse_overrides || return 1
  guard_paths || return 1
  [ -f "$CONFIG" ] || { err "not prepared (run '$0 prepare healthy' first)"; return 1; }
  redact_refresh
  mkdir -p "$LOGS"
  local launch_id="unknown"
  [ -f "$LAUNCH_FILE" ] && launch_id="$(cat "$LAUNCH_FILE")"

  # (a) config identity: expected loopback topology, never prod values.
  local pglist
  pglist="$(config_val 'server\.pglist')"
  [ "$pglist" = "127.0.10.11:5432,127.0.10.12:5433" ] \
    || { err "unexpected server.pglist='$pglist' (want 127.0.10.11:5432,127.0.10.12:5433)"; return 1; }
  [ "$(config_val 'watcher\.cluster-port')" = "9995" ] \
    || { err "unexpected watcher.cluster-port (want 9995)"; return 1; }
  [ "$(config_val 'watcher\.cluster-pair')" = "no-pair" ] \
    || { err "unexpected watcher.cluster-pair (want no-pair)"; return 1; }
  case "$pglist" in 127.*) ;; *) err "refusing non-loopback pglist: $pglist"; return 1;; esac

  # (b) stub health: bounded polling of every tuple (TCP connect, proxy-free).
  local t ip port
  for t in $STUB_TUPLES; do
    ip="${t%%:*}"; port="${t##*:}"
    if poll_until "$VALIDATE_TIMEOUT_STUBS" tcp_probe "$ip" "$port"; then
      note "stub $t: UP"
    else
      err "stub $t: NOT LISTENING after ${VALIDATE_TIMEOUT_STUBS}s (run '$0 start-dependencies')"
      return 1
    fi
  done

  # (c) minipg HTTP speaks (best-effort liveness; any HTTP status proves HTTP).
  local pguser pgpass code
  pguser="$(config_val 'server\.pguser')"; pgpass="$(config_val 'server\.pgpassword')"
  local muser="$(config_val 'minipg\.username')" mpass="$(config_val 'minipg\.password')"
  [ -n "$pgpass" ] && [ -n "$mpass" ] \
    || { err "cannot prove redaction: generated secrets missing in $CONFIG"; return 1; }
  for ip in "$PG1_IP" "$PG2_IP"; do
    code="$(http_probe "http://$ip:$MINIPG_PORT/pgstatus" "$muser:$mpass" || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      note "minipg $ip:$MINIPG_PORT: HTTP $code"
    else
      note "minipg $ip:$MINIPG_PORT: WARN no HTTP response on /pgstatus (TCP is up; fixtures may map other routes)"
    fi
  done

  # (d) fixture bytes: expected content (fail-closed, no stub-only excuse).
  local dst="$FAST_DIR/fixtures/healthy" bytes=0
  if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
    bytes="$(find "$dst" -type f -size +0c 2>/dev/null | wc -l)"
    [ "$bytes" -gt 0 ] || { err "fixtures at $dst contain no non-empty files"; return 1; }
    note "fixtures: $bytes non-empty file(s) under $dst"
  else
    err "fixtures at $dst empty/missing (run '$0 prepare healthy' first)"
    return 1
  fi

  # (e) BFM evidence is REQUIRED: fail when the IDE/helper-owned BFM is absent.
  if ! tuple_listening "$BFM_IP" "$BFM_PORT"; then
    err "BFM $BFM_TUPLE: not listening - BFM evidence is required (start it via F5 'BFM - fast environment' or '$0 start', then re-run)"
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

  # -- bfm_status.json: retry-on-truncated-write, expected HEALTHY + roles.
  note "waiting for fresh $STATE (launch-id=$launch_id) ..."
  local st_file
  st_file="$(mktemp)"
  if ! poll_until "$VALIDATE_TIMEOUT_STATE" python3 - "$STATE" "$st_file" <<'EOF'
import json, sys
state, out = sys.argv[1], sys.argv[2]
d = json.load(open(state))  # raises on truncated/partial write -> poll retries
assert d.get("clusterStatus") == "HEALTHY", d.get("clusterStatus")
got = {s["address"]: s.get("databaseStatus") for s in d.get("clusterServers", [])}
assert set(got) == {"127.0.10.11:5432", "127.0.10.12:5433"}, got
assert sorted(got.values()) == ["MASTER", "SLAVE"], got
open(out, "w").write(json.dumps(got, sort_keys=True))
EOF
  then
    err "state check failed after ${VALIDATE_TIMEOUT_STATE}s: want clusterStatus=HEALTHY with 127.0.10.11:5432 + 127.0.10.12:5433 as MASTER/SLAVE (tolerant of truncated rewrites; see $STATE)"
    rm -f "$st_file"
    return 1
  fi
  # Freshness: state must be newer than this launch (prepare deletes stale state).
  if [ "$STATE" -ot "$LAUNCH_FILE" ]; then
    err "stale $STATE (older than launch-id $launch_id); restart BFM on the current CONFIG"
    rm -f "$st_file"
    return 1
  fi
  note "state: HEALTHY roles=$(cat "$st_file")"
  rm -f "$st_file"

  # -- fresh BFM log evidence anchored by launch id (bounded polling).
  # Healthy floor: 5s checkCluster (per-node Status + Cluster Status + active),
  # 11s amIMasterBfm no-pair discovery + 11s VIP check, 9s-initial autoconf
  # clean, 30s pgpass update. 6s fixappname + 7s checkUnavailable are
  # silent-by-design when healthy (no repair/INACCESSIBLE), so their opportunity
  # is proven via the longer intervals above, not a positive line.
  # pairStatus starts "Active", so the no-pair/active lines prove real discovery,
  # not just startup.
  local bfm_log="$LOGS/app.log" pat
  [ -f "$bfm_log" ] \
    || { err "BFM log $bfm_log absent (BFM must run with CWD=$run_canon so logging.file.name resolves here)"; return 1; }
  if [ "$bfm_log" -ot "$LAUNCH_FILE" ]; then
    err "stale BFM log $bfm_log (older than launch-id $launch_id); restart BFM on the current CONFIG"
    return 1
  fi
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

  # -- Redaction tripwire (fail-closed): generated secrets must never hit stored logs.
  # Helper/stub logs go through pre-storage redaction; the IDE-owned BFM writes
  # $bfm_log directly, so any secret there means the path cannot be redacted.
  local f
  if grep -qF -- "$pgpass" "$bfm_log" 2>/dev/null || grep -qF -- "$mpass" "$bfm_log" 2>/dev/null; then
    err "stored BFM log $bfm_log contains generated credentials (pre-storage redaction failed; refusing)"
    return 1
  fi
  for f in "$HELPER_LOG" "$LOGS"/stub-*.log "$LOGS"/bfm-helper.log; do
    [ -f "$f" ] || continue
    if grep -qF -- "$pgpass" "$f" 2>/dev/null || grep -qF -- "$mpass" "$f" 2>/dev/null; then
      err "stored log $f contains generated credentials (pre-storage redaction failed; refusing)"
      return 1
    fi
  done

  log "validate-dependencies launch=$launch_id result=full-ok"
  note "validate-dependencies: OK (full, launch-id=$launch_id)"
  return 0
}

# --- status ----------------------------------------------------------------------
cmd_status() {
  guard_paths || return 1
  if [ ! -f "$CONFIG" ]; then note "fast-env: not prepared (run '$0 prepare healthy' first)"; return 0; fi
  local launch_id="unknown"
  [ -f "$LAUNCH_FILE" ] && launch_id="$(cat "$LAUNCH_FILE")"
  note "launch-id=$launch_id scenario=$(cat "$SCENARIO_FILE" 2>/dev/null || echo unknown)"
  note "server.pglist=$(config_val 'server\.pglist')"
  note "watcher.cluster-port=$(config_val 'watcher\.cluster-port') watcher.cluster-pair=$(config_val 'watcher\.cluster-pair') minipg.port=$(config_val 'minipg\.port')"
  local t addr port
  for t in $STUB_TUPLES; do
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
  if [ -f "$PIDS_FILE" ]; then
    if pids_alive "$PIDS_FILE"; then note "helper pids ($PIDS_FILE): ALIVE"; else note "helper pids ($PIDS_FILE): stale/none"; fi
  else
    note "helper pids: none"
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
  local f found=0
  for f in "$HELPER_LOG" "$LOGS"/stub-*.log "$LOGS"/bfm-helper.log "$LOGS"/app.log; do
    [ -f "$f" ] || continue
    found=1
    note "== $f (last $n lines, redacted) =="
    tail -n "$n" "$f" 2>/dev/null | redact || true
  done
  [ "$found" = "1" ] || note "no logs yet under $LOGS (run prepare/start first)"
  return 0
}

# --- stop ------------------------------------------------------------------------
cmd_stop() {
  refuse_overrides || return 1
  guard_paths || return 1
  check_owner stop || return 1
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
  # Verify helper-owned BFM tuple freed (never touch IDE-owned BFM).
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
  [ -e "$FAST_DIR" ] || { note "reset: nothing to do ($FAST_DIR absent)"; return 0; }
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
  rm -rf -- "$FAST_DIR"
  note "reset: removed $FAST_DIR (tool cache kept at $TOOL_CACHE; repo-root bfm_status.json and _work-tmp/local/ untouched)"
  return 0
}

# --- start / validate (helper-owned BFM wrappers; milestone 2 primary) -------------
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

# --- dispatch ----------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

  prepare [healthy]       generate config/run/logs + copy fixtures + verify WireMock cache (v1: healthy only)
  start-dependencies      adopt or launch pgwire stubs + per-IP WireMock JVMs on the 4 stub tuples
  validate-dependencies   bounded-poll validation (deps + BFM evidence REQUIRED; fails when BFM absent)
  status                  show tuples, pids, config, state summary (read-only)
  logs [N]                tail redacted logs (default 100 lines)
  stop                    stop helper-owned processes only (never IDE-owned BFM)
  reset                   delete _work-tmp/fast-env/ (refuses while IDE BFM active)
  start                   start-dependencies + helper-owned BFM from built jar
  validate                validate-dependencies for helper-owned BFM (refuses otherwise)
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
    -h|--help|help|"")     usage; return 0 ;;
    *) err "unknown command '$cmd'"; usage >&2; return 2 ;;
  esac
}

main "$@"
