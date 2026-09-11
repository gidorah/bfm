#!/usr/bin/env bash
# bfm-live node entrypoint (issue #18, part B): bootstrap + start local
# PostgreSQL, then exec the MiniPG agent as PID1 (so `docker stop` SIGTERMs
# the agent, which stops PG cleanly before exiting).
#
# Roles (env NODE_ROLE):
#   primary: initdb when PGDATA is empty, then start.
#   replica: bounded-wait for PRIMARY_HOST:PRIMARY_PORT, then
#     pg_basebackup -R when PGDATA is empty, then start.
# A non-empty PGDATA (e.g. `docker start` after `docker stop`) is started
# as-is: BFM owns failover and drives rewind/rejoin via the agent.
#
# PG tuning comes from "$@" (the compose `command:` block: the `-c` flags);
# it is saved to $OPTS_FILE so agent-driven restarts reuse the exact flags.
# Synchronous replication is NOT preset (BFM sets it via setsync at runtime).
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
POSTGRES_USER="${POSTGRES_USER:-bfm}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-bfm}"
NODE_ROLE="${NODE_ROLE:-primary}"
PRIMARY_HOST="${PRIMARY_HOST:-live-pg1}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-180}"
AGENT="${AGENT:-/opt/bfm/minipg-agent.py}"
HBA_SNIPPET="${HBA_SNIPPET:-/opt/bfm/docker/pg_hba.live.conf}"
HBA_MARKER="bfm-live-trust-BEGIN"
OPTS_FILE="${PG_OPTS_FILE:-/var/lib/postgresql/bfm-pg-opts}"
PGPASS_FILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"

log() { echo "[entrypoint:$NODE_NAME] $*" >&2; }

# as_pg <cmd...>: run as the postgres OS user (PGDATA owner).
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

# Save the PG -c flags for agent-driven restarts (outside PGDATA: rebaseUp
# wipes PGDATA contents, and this file must survive that).
EXTRA_OPTS="$*"
mkdir -p "$(dirname "$OPTS_FILE")"
printf '%s' "$EXTRA_OPTS" >"$OPTS_FILE"
chmod 644 "$OPTS_FILE" 2>/dev/null || true
log "pg opts: ${EXTRA_OPTS:-<none>}"

mkdir -p "$PGDATA" /var/run/postgresql
if [ "$(id -u)" = "0" ]; then
  chown -R postgres:postgres "$PGDATA" 2>/dev/null || true
fi

ensure_hba() {
  if [ ! -f "$PGDATA/pg_hba.conf" ]; then
    return 0
  fi
  if grep -q "$HBA_MARKER" "$PGDATA/pg_hba.conf" 2>/dev/null; then
    return 0
  fi
  cat "$HBA_SNIPPET" >>"$PGDATA/pg_hba.conf"
  if [ "$(id -u)" = "0" ]; then
    chown postgres:postgres "$PGDATA/pg_hba.conf" 2>/dev/null || true
  fi
  log "pg_hba: appended disposable trust snippet (DO NOT use in production)"
}

# Seed .pgpass so pg_rewind/pg_basebackup (which use PGPASSWORD or .pgpass)
# and the agent's standby primary_conninfo (no password stored) can connect.
seed_pgpass() {
  local line added=0
  touch "$PGPASS_FILE" 2>/dev/null || return 0
  for line in \
    "live-pg1:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "live-pg2:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "127.0.10.11:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "127.0.10.12:5433:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "localhost:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" \
    "127.0.0.1:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}"; do
    if ! grep -qxF "$line" "$PGPASS_FILE" 2>/dev/null; then
      printf '%s\n' "$line" >>"$PGPASS_FILE"
      added=1
    fi
  done
  chmod 600 "$PGPASS_FILE" 2>/dev/null || true
  if [ "$(id -u)" = "0" ]; then
    chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
  fi
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
  if [ "$(id -u)" = "0" ]; then
    chown -R postgres:postgres "$PGDATA" "$PGDATA/log" 2>/dev/null || true
    chmod 0700 "$PGDATA" 2>/dev/null || true
  else
    chmod 0700 "$PGDATA" 2>/dev/null || true
  fi
  if [ -n "$EXTRA_OPTS" ]; then
    # shellcheck disable=SC2086
    as_pg pg_ctl -D "$PGDATA" -l "$PGDATA/log/postgresql.log" -w -t 60 -o "$EXTRA_OPTS" start
  else
    as_pg pg_ctl -D "$PGDATA" -l "$PGDATA/log/postgresql.log" -w -t 60 start
  fi
}

set_superuser_password() {
  # Trust auth is in force (disposable only); still honor POSTGRES_PASSWORD so
  # the credential works if auth is ever tightened. Fixed test-only value.
  local esc="${POSTGRES_PASSWORD//\'/\'\'}"
  as_pg psql -h /var/run/postgresql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -tAc \
    "ALTER USER \"${POSTGRES_USER}\" WITH PASSWORD '${esc}';" >/dev/null
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  log "empty data dir; bootstrapping as ${NODE_ROLE}"
  case "$NODE_ROLE" in
    replica)
      wait_for_primary
      PGPASSWORD="$POSTGRES_PASSWORD" as_pg pg_basebackup -R \
        -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$POSTGRES_USER" \
        -D "$PGDATA" -c fast
      inject_appname
      ;;
    *)
      as_pg initdb -D "$PGDATA" -U "$POSTGRES_USER" -E UTF8 --auth=trust
      ;;
  esac
else
  log "existing data dir; starting as-is (BFM owns failover)"
fi

ensure_hba
seed_pgpass
start_pg
set_superuser_password || log "WARN: could not set superuser password (trust auth still applies)"
log "PG up; exec agent"

if [ "$(id -u)" = "0" ]; then
  if command -v gosu >/dev/null 2>&1; then
    exec gosu postgres python3 "$AGENT"
  else
    exec su -s /bin/bash postgres -c "exec python3 $AGENT"
  fi
else
  exec python3 "$AGENT"
fi
