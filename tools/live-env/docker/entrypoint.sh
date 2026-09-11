#!/usr/bin/env bash
# bfm-live node entrypoint (issue #23, part A): bootstrap + start local
# PostgreSQL, then supervise the REAL minipg4patroni sidecar jar in the same
# container (no Patroni: BFM owns failover).
#
# Supervision (per reference member-entrypoint.sh): start the DB, wait for
# health, then `java -jar minipg.jar &` with `wait` + TERM/INT forwarding —
# SIGTERM kills the jar first, then stops PG cleanly before exiting.
# The jar's CWD MUST be the dir containing per-node ./configuration.json
# (ConfigurationManager reads CWD-relative ./configuration.json), so the jar
# is launched with CWD=/opt/bfm where the image COPYs the single static
# tools/live-env/configuration.json (node-identical values; Dockerfile
# header documents why no per-node templating is needed).
#
# Roles (env NODE_ROLE):
#   primary: initdb when PGDATA is empty, then start.
#   replica: bounded-wait for PRIMARY_HOST:PRIMARY_PORT, then
#     pg_basebackup -R when PGDATA is empty, then start.
# A non-empty PGDATA (e.g. `docker start` after `docker stop`) is started
# as-is: BFM owns failover and drives rewind/rejoin via the jar.
#
# PG tuning comes from "$@" (the compose `command:` block: the `-c` flags);
# it is saved to $OPTS_FILE so jar-driven restarts reuse the exact flags.
# Synchronous replication is NOT preset (BFM sets it via setsync at runtime).
# The jar's `bfm` mode also enforces wal_log_hints/hot_standby itself at
# startup (MiniPGHelper.init) — both agree.
#
# Root handling (per reference): when started as root, fix ownership of
# PGDATA + /opt/bfm, then re-exec this script as the postgres OS user so
# everything below — including the jar — runs as postgres (owner of PG
# paths). gosu is preferred (present in postgres:14 images), su fallback.
#
# VIP note: vipInterface is eth0 (bridge default; see configuration.json).
# check_vip_iface logs the live `ip address show` at boot and warns when
# eth0 is absent — if a runtime ever shows another interface, update
# configuration.json vipInterface and rebuild (do not assume).
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
POSTGRES_USER="${POSTGRES_USER:-bfm}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-bfm}"
NODE_ROLE="${NODE_ROLE:-primary}"
PRIMARY_HOST="${PRIMARY_HOST:-172.30.51.11}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-180}"
JAR="${JAR:-/opt/bfm/minipg.jar}"
JAR_CWD="${JAR_CWD:-/opt/bfm}"
JAVA_OPTS="${JAVA_OPTS:- -Xms64m -Xmx256m}"
HBA_SNIPPET="${HBA_SNIPPET:-/opt/bfm/docker/pg_hba.live.conf}"
HBA_MARKER="bfm-live-trust-BEGIN"
OPTS_FILE="${PG_OPTS_FILE:-/var/lib/postgresql/bfm-pg-opts}"
PGPASS_FILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"
VIP_INTERFACE="${VIP_INTERFACE:-eth0}"

log() { echo "[entrypoint:$NODE_NAME] $*" >&2; }

# as_pg <cmd...>: run as the postgres OS user (PGDATA owner). After the
# root re-exec below this is a no-op; kept for direct postgres launches.
as_pg() {
  if [ "$(id -u)" = "0" ]; then
    if command -v gosu >/dev/null 2>&1; then
      gosu postgres "$@"
    else
      su -s /bin/bash postgres -c "$*"
    fi
  else
    "$@"
  fi
}

# --- root prelude: fix ownership, then re-exec as postgres --------------------
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$PGDATA" /var/run/postgresql /opt/bfm
  chown -R postgres:postgres "$PGDATA" /var/run/postgresql /opt/bfm 2>/dev/null || true
  log "re-exec as postgres"
  if command -v gosu >/dev/null 2>&1; then
    exec gosu postgres "$0" "$@"
  else
    exec su -s /bin/bash postgres -c "exec $0 $*"
  fi
fi

# --- from here on we run as postgres ------------------------------------------

# Save the PG -c flags for jar-driven restarts (outside PGDATA: rebaseUp
# wipes PGDATA contents, and this file must survive that).
EXTRA_OPTS="$*"
mkdir -p "$(dirname "$OPTS_FILE")"
printf '%s' "$EXTRA_OPTS" >"$OPTS_FILE"
chmod 644 "$OPTS_FILE" 2>/dev/null || true
log "pg opts: ${EXTRA_OPTS:-<none>}"

mkdir -p "$PGDATA" /var/run/postgresql
chmod 0700 "$PGDATA" 2>/dev/null || true

ensure_hba() {
  if [ ! -f "$PGDATA/pg_hba.conf" ]; then
    return 0
  fi
  if grep -q "$HBA_MARKER" "$PGDATA/pg_hba.conf" 2>/dev/null; then
    return 0
  fi
  cat "$HBA_SNIPPET" >>"$PGDATA/pg_hba.conf"
  log "pg_hba: appended disposable trust snippet (DO NOT use in production)"
}

# Seed .pgpass so pg_rewind/pg_basebackup and the jar's standby
# primary_conninfo can connect. Pinned bridge topology: both nodes serve PG
# on 5432 (distinct IPs, same port) + the moving VIP.
seed_pgpass() {
  local line added=0
  touch "$PGPASS_FILE" 2>/dev/null || return 0
  for line in \
    "live-pg1:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "live-pg2:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "172.30.51.11:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "172.30.51.12:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "172.30.51.100:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "localhost:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "127.0.0.1:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}"; do
    if ! grep -qxF "$line" "$PGPASS_FILE" 2>/dev/null; then
      printf '%s\n' "$line" >>"$PGPASS_FILE"
      added=1
    fi
  done
  chmod 600 "$PGPASS_FILE" 2>/dev/null || true
  if [ "$added" = "1" ]; then
    log "seeded .pgpass"
  fi
}

wait_for_primary() {
  local waited=0
  log "replica: waiting up to ${BOOT_WAIT_SECS}s for ${PRIMARY_HOST}:${PRIMARY_PORT}"
  until pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" >/dev/null 2>&1; do
    waited=$((waited + 2))
    if [ "$waited" -ge "$BOOT_WAIT_SECS" ]; then
      log "replica: primary ${PRIMARY_HOST}:${PRIMARY_PORT} not ready after ${BOOT_WAIT_SECS}s"
      return 1
    fi
    sleep 2
  done
  log "replica: primary reachable after ${waited}s"
}

inject_appname() {
  # Give the walreceiver a stable application_name (not walreceiver/main) so
  # BFM's appname fix loop stays quiet; best effort only.
  local auto="$PGDATA/postgresql.auto.conf"
  if [ -f "$auto" ] && grep -q "^primary_conninfo" "$auto" && ! grep -q "application_name" "$auto"; then
    sed -i "s/^primary_conninfo = '/primary_conninfo = 'application_name=${NODE_NAME} /" "$auto"
    log "standby application_name=${NODE_NAME}"
  fi
}

start_pg() {
  mkdir -p "$PGDATA/log"
  chmod 0700 "$PGDATA" 2>/dev/null || true
  if [ -n "$EXTRA_OPTS" ]; then
    # shellcheck disable=SC2086
    pg_ctl -D "$PGDATA" -l "$PGDATA/log/postgresql.log" -w -t 60 -o "$EXTRA_OPTS" start
  else
    pg_ctl -D "$PGDATA" -l "$PGDATA/log/postgresql.log" -w -t 60 start
  fi
}

set_superuser_password() {
  # Trust auth is in force (disposable only); still honor POSTGRES_PASSWORD so
  # the credential works if auth is ever tightened. Fixed test-only value.
  local esc="${POSTGRES_PASSWORD//\'/\'\'}"
  psql -h /var/run/postgresql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -tAc \
    "ALTER USER \"${POSTGRES_USER}\" WITH PASSWORD '${esc}';" >/dev/null
}

persist_pg_settings() {
  # Persist the rejoin-critical settings via ALTER SYSTEM so they survive
  # jar-driven restarts (issue #23): the entrypoint boots PG with -o -c
  # flags (in-memory only), but the real jar's rewind/rebaseUp path runs
  # `pg_ctl start` WITHOUT those flags — a rejoined node would come back
  # with wal_log_hints=off and break the next pg_rewind. ALTER SYSTEM writes
  # postgresql.auto.conf, which pg_basebackup copies to replicas and
  # pg_rewind preserves/copies, so one persist at bootstrap covers every
  # future failover. Best effort: effective values are already on via -o.
  psql -h /var/run/postgresql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -tAc \
    "ALTER SYSTEM SET wal_log_hints = on;" >/dev/null \
  && psql -h /var/run/postgresql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -tAc \
    "ALTER SYSTEM SET hot_standby = on;" >/dev/null \
  && psql -h /var/run/postgresql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -tAc \
    "SELECT pg_reload_conf();" >/dev/null \
  && log "pg settings persisted (wal_log_hints=on, hot_standby=on)" \
  || log "WARN: could not persist pg settings via ALTER SYSTEM (jar-driven restarts may lose wal_log_hints)"
}

wait_pg_healthy() {
  local waited=0
  until pg_isready -h /var/run/postgresql -U "$POSTGRES_USER" >/dev/null 2>&1; do
    waited=$((waited + 1))
    if [ "$waited" -ge 60 ]; then
      log "PG not ready after 60s"
      return 1
    fi
    sleep 1
  done
  log "PG healthy after ${waited}s"
}

check_vip_iface() {
  # Runtime verification for configuration.json vipInterface (default eth0):
  # log live interfaces; warn when the configured one is absent so the
  # mismatch is visible instead of failing silently at vip-up time.
  if command -v ip >/dev/null 2>&1; then
    log "net interfaces: $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | paste -sd, - || echo unknown)"
    if ip link show "$VIP_INTERFACE" >/dev/null 2>&1; then
      log "vip interface $VIP_INTERFACE present"
    else
      log "WARN: vip interface $VIP_INTERFACE absent (update configuration.json vipInterface + rebuild if persistent)"
    fi
  else
    log "WARN: ip(8) not on PATH (VIP ops will fail)"
  fi
  if sudo -n /bin/true >/dev/null 2>&1; then
    log "sudo postVipUp grant OK"
  else
    log "WARN: passwordless sudo /bin/true missing for $(id -un) (vip-up post step will fail)"
  fi
}

check_jar_config() {
  if [ ! -f "$JAR_CWD/configuration.json" ]; then
    log "FATAL: $JAR_CWD/configuration.json absent (jar reads CWD-relative ./configuration.json)"
    return 1
  fi
  if [ ! -r "$JAR_CWD/configuration.json" ]; then
    log "FATAL: $JAR_CWD/configuration.json unreadable by $(id -un) (bind-mount perms; want 644)"
    return 1
  fi
  if ! grep -q '"clusterManager"[[:space:]]*:[[:space:]]*"bfm"' "$JAR_CWD/configuration.json"; then
    log "FATAL: configuration.json lacks clusterManager bfm (jar NPEs / skips PG auto-manage)"
    return 1
  fi
  log "jar config OK (clusterManager bfm)"
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  log "empty data dir; bootstrapping as ${NODE_ROLE}"
  case "$NODE_ROLE" in
    replica)
      wait_for_primary
      PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -R \
        -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$POSTGRES_USER" \
        -D "$PGDATA" -c fast
      inject_appname
      ;;
    *)
      initdb -D "$PGDATA" -U "$POSTGRES_USER" -E UTF8 --auth=trust
      ;;
  esac
else
  log "existing data dir; starting as-is (BFM owns failover)"
fi

ensure_hba
seed_pgpass
start_pg
set_superuser_password || log "WARN: could not set superuser password (trust auth still applies)"
persist_pg_settings || true
wait_pg_healthy
check_vip_iface || true

if [ ! -f "$JAR" ]; then
  log "FATAL: sidecar jar absent at $JAR (prepare stages it; see Dockerfile header)"
  exit 1
fi
check_jar_config

# --- sidecar supervision (reference pattern): jar as background child ---------
cd "$JAR_CWD" || { log "FATAL: cannot cd to jar CWD $JAR_CWD"; exit 1; }
log "jar CWD=$(pwd); starting sidecar"

JAR_PID=""
terminate() {
  trap - TERM INT
  if [ -n "$JAR_PID" ]; then
    kill -TERM "$JAR_PID" 2>/dev/null || true
    wait "$JAR_PID" 2>/dev/null || true
  fi
  pg_ctl -D "$PGDATA" -w -t 60 stop >/dev/null 2>&1 || true
}
trap 'terminate; exit 143' TERM INT

# shellcheck disable=SC2086
java $JAVA_OPTS -jar "$JAR" &
JAR_PID=$!
log "sidecar pid=$JAR_PID"

set +e
wait -n "$JAR_PID"
STATUS=$?
set -e
log "sidecar exited status=$STATUS; stopping PG"
pg_ctl -D "$PGDATA" -w -t 60 stop >/dev/null 2>&1 || true
exit "$STATUS"
