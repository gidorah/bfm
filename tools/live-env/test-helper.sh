#!/usr/bin/env bash
# live-env helper self-test (issue #18, part C).
# Seams under test (public interfaces only):
#   1. tools/live-env/live-env.sh CLI: exit codes + filesystem effects under _work-tmp/live-env/
#   2. justfile live-* recipes: presence + delegation to the script (local-*/fast-* untouched)
# Does NOT touch: repo-root bfm_status.json, _work-tmp/local/, _work-tmp/fast-env/, docs/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/tools/live-env/live-env.sh"
LIVE_DIR="$REPO_ROOT/_work-tmp/live-env"
PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

# --- hermeticity guards -------------------------------------------------------
ROOT_SUM_BEFORE="$(sha256sum "$REPO_ROOT/bfm_status.json" | cut -d' ' -f1)"
LOCAL_SUM_BEFORE="$(find "$REPO_ROOT/_work-tmp/local" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1)"
FAST_SUM_BEFORE="$(find "$REPO_ROOT/_work-tmp/fast-env" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1)"
CREATED_BY_TEST=0
[ -e "$LIVE_DIR" ] || CREATED_BY_TEST=1

helper_stop() { [ -f "$HELPER" ] && bash "$HELPER" stop > /dev/null 2>&1 || true; }
trap 'helper_stop' EXIT

docker_available() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
run_limited() { # run_limited <secs> <cmd...>: timeout when available, plain run otherwise
  if command -v timeout >/dev/null 2>&1; then timeout "$1" "${@:2}"; else "${@:2}"; fi
}

# --- 0. helper exists ----------------------------------------------------------
if [ -f "$HELPER" ]; then
  ok "helper exists at tools/live-env/live-env.sh"
  [ -x "$HELPER" ] && ok "helper is executable" || bad "helper is executable"
else
  bad "helper exists at tools/live-env/live-env.sh (worker A not landed yet)"
  echo "---"
  echo "self-test: $PASS passed, $FAIL failed, $SKIP skipped (helper missing; runtime sections skipped)"
  [ "$FAIL" = "0" ]
fi

# --- 1. prepare healthy creates expected layout (docker-independent) ------------
# Prove docker-independence: hide any real docker behind a failing shim.
SHIM_DIR="$(mktemp -d)"
echo 'echo "SHIM: docker $*" >> "$SHIM_LOG"; exit 1' >"$SHIM_DIR/docker"
chmod +x "$SHIM_DIR/docker"
export SHIM_LOG="$SHIM_DIR/calls.log"
: >"$SHIM_LOG"
PREP_OUT="$(mktemp)"
if PATH="$SHIM_DIR:$PATH" bash "$HELPER" prepare healthy >"$PREP_OUT" 2>&1; then
  ok "prepare healthy exits 0 without a usable docker daemon"
else
  bad "prepare healthy exits 0 without a usable docker daemon (see $PREP_OUT)"
fi
for f in application.properties run logs .launch-id .owner .scenario compose.yaml; do
  [ -e "$LIVE_DIR/$f" ] && ok "prepare creates $f" || bad "prepare creates $f"
done
grep -Eq '^[[:space:]]*watcher\.cluster-port[[:space:]]*=[[:space:]]*9995' "$LIVE_DIR/application.properties" \
  && ok "config watcher.cluster-port=9995" || bad "config watcher.cluster-port=9995"
grep -Eq '^[[:space:]]*server\.pglist[[:space:]]*=[[:space:]]*127\.0\.10\.11:5432,127\.0\.10\.12:5433' "$LIVE_DIR/application.properties" \
  && ok "config server.pglist loopback topology" || bad "config server.pglist loopback topology"
grep -Eq '^[[:space:]]*watcher\.cluster-pair[[:space:]]*=[[:space:]]*no-pair' "$LIVE_DIR/application.properties" \
  && ok "config watcher.cluster-pair=no-pair" || bad "config watcher.cluster-pair=no-pair"
grep -Eq '^[[:space:]]*minipg\.port[[:space:]]*=[[:space:]]*7779' "$LIVE_DIR/application.properties" \
  && ok "config minipg.port=7779" || bad "config minipg.port=7779"
for key in 'server\.pguser' 'server\.pgpassword' 'minipg\.username' 'minipg\.password'; do
  VAL="$(grep -E "^[[:space:]]*$key[[:space:]]*=" "$LIVE_DIR/application.properties" | sed 's/.*=[[:space:]]*//' | tail -n 1)"
  if [ "$VAL" = "bfm" ]; then
    ok "config $key=bfm (fixed test-only creds)"
  else
    bad "config $key=bfm (fixed test-only creds, got '$VAL')"
  fi
done
[ "$(cat "$LIVE_DIR/.scenario" 2>/dev/null)" = "healthy" ] \
  && ok "prepare records .scenario=healthy" \
  || bad "prepare records .scenario=healthy"
rm -rf "$SHIM_DIR"

# --- 2. staged compose.yaml carries the fixed topology --------------------------
COMPOSE="$LIVE_DIR/compose.yaml"
if [ -f "$COMPOSE" ]; then
  for lit in 'live-pg1' 'live-pg2' 'bfm-live-pg1' 'bfm-live-pg2' '127.0.10.11' '127.0.10.12' 'wal_log_hints'; do
    grep -qF "$lit" "$COMPOSE" && ok "compose.yaml contains $lit" || bad "compose.yaml contains $lit"
  done
  grep -qE '(^|[^0-9])5432([^0-9]|$)' "$COMPOSE" && ok "compose.yaml exposes PG 5432" || bad "compose.yaml exposes PG 5432"
  grep -qE '(^|[^0-9])5433([^0-9]|$)' "$COMPOSE" && ok "compose.yaml exposes PG 5433" || bad "compose.yaml exposes PG 5433"
  grep -qE '(^|[^0-9])7779([^0-9]|$)' "$COMPOSE" && ok "compose.yaml exposes MiniPG 7779" || bad "compose.yaml exposes MiniPG 7779"
else
  bad "compose.yaml staged (missing $COMPOSE)"
fi
# Project name lives on the docker CLI invocation (compose file need not carry it).
grep -qF "bfm-live" "$HELPER" \
  && ok "helper pins compose project bfm-live" \
  || bad "helper pins compose project bfm-live"

# --- 3. prepare rejects unknown + deferred scenarios (fail-closed) ---------------
if bash "$HELPER" prepare bogus-scenario > /dev/null 2>&1; then
  bad "prepare rejects unknown scenario"
else
  ok "prepare rejects unknown scenario"
fi
for s in replica-data-loss lag-threshold switchover-tablespaces pair-takeover; do
  OUT="$(mktemp)"
  if bash "$HELPER" prepare "$s" >"$OUT" 2>&1; then
    bad "prepare rejects deferred scenario $s (fail-closed)"
  else
    if grep -qiE "deferred|not yet|unsupported|unknown" "$OUT"; then
      ok "prepare rejects deferred scenario $s (fail-closed)"
    else
      bad "prepare rejects deferred scenario $s (fail-closed; no clear message)"
    fi
  fi
done

# --- 4. prepare accepts kill-primary, keeps identical topology -------------------
if bash "$HELPER" prepare kill-primary > /dev/null 2>&1; then
  ok "prepare accepts kill-primary"
else
  bad "prepare accepts kill-primary"
fi
[ "$(cat "$LIVE_DIR/.scenario" 2>/dev/null)" = "kill-primary" ] \
  && ok "prepare records .scenario=kill-primary" \
  || bad "prepare records .scenario=kill-primary"
PGLIST_K="$(grep -E '^[[:space:]]*server\.pglist[[:space:]]*=' "$LIVE_DIR/application.properties" | sed 's/.*=[[:space:]]*//' || true)"
[ "$PGLIST_K" = "127.0.10.11:5432,127.0.10.12:5433" ] \
  && ok "kill-primary keeps identical topology (server.pglist)" \
  || bad "kill-primary keeps identical topology (server.pglist, got '$PGLIST_K')"
bash "$HELPER" prepare healthy > /dev/null 2>&1

# --- 5. kill-primary / rejoin actions exist and fail closed with nothing running --
for act in kill-primary rejoin; do
  OUT="$(mktemp)"
  if grep -q "$act)" "$HELPER"; then
    ok "helper dispatches action $act"
  else
    bad "helper dispatches action $act"
    continue
  fi
  if run_limited 60 bash "$HELPER" "$act" >"$OUT" 2>&1; then
    bad "$act fails closed with no running stack"
  else
    if grep -qiE "unknown command" "$OUT"; then
      bad "$act fails closed with no running stack (reported as unknown command)"
    elif grep -qiE "not running|not prepared|no stack|start-dependencies|prepare" "$OUT"; then
      ok "$act fails closed with no running stack"
    else
      bad "$act fails closed with no running stack (no clear message)"
    fi
  fi
done

# --- 6. unknown command refused --------------------------------------------------
if bash "$HELPER" bogus-command > /dev/null 2>&1; then
  bad "unknown command refused"
else
  ok "unknown command refused"
fi

# --- 7. status / logs / stop work without side effects ---------------------------
bash "$HELPER" status > /dev/null 2>&1 && ok "status exits 0" || bad "status exits 0"
bash "$HELPER" logs 5 > /dev/null 2>&1 && ok "logs exits 0" || bad "logs exits 0"
bash "$HELPER" stop > /dev/null 2>&1 && ok "stop exits 0 when nothing running" || bad "stop exits 0 when nothing running"

# --- 8. validate wrappers fail clearly with nothing running (no daemon needed) ----
VAL_OUT="$(mktemp)"
if run_limited 120 bash "$HELPER" validate-dependencies >"$VAL_OUT" 2>&1; then
  bad "validate-dependencies fails clearly with no dependencies running"
else
  if grep -qiE "missing|not listening|not running|refus|no stub|not prepared" "$VAL_OUT"; then
    ok "validate-dependencies fails clearly with no dependencies running"
  else
    bad "validate-dependencies fails clearly with no dependencies running (no clear message)"
  fi
fi
if run_limited 60 bash "$HELPER" validate > /dev/null 2>&1; then
  bad "validate refuses without helper-owned BFM"
else
  ok "validate refuses without helper-owned BFM"
fi

# --- 9. docker-dependent live checks (SKIP when daemon absent) --------------------
if docker_available; then
  if run_limited 300 bash "$HELPER" start-dependencies > /dev/null 2>&1; then
    ok "start-dependencies brings up live stack"
  else
    bad "start-dependencies brings up live stack"
  fi
else
  skip "start-dependencies brings up live stack (no docker daemon)"
  skip "validate greens on healthy with real MASTER/SLAVE (no docker daemon)"
fi

# --- 10. just live-* delegates; just local-*/fast-* untouched ---------------------
if grep -Eq '^live-prepare' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-start-dependencies' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-validate-dependencies' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-status' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-logs' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-stop' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-reset' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-validate' "$REPO_ROOT/justfile" \
  && grep -q 'kill-primary' "$REPO_ROOT/justfile" \
  && grep -q 'rejoin' "$REPO_ROOT/justfile" \
  && grep -q 'tools/live-env/live-env.sh' "$REPO_ROOT/justfile"; then
  ok "just live-* recipes delegate to helper"
else
  bad "just live-* recipes delegate to helper"
fi
for r in local-prepare local-reset local-status local-logs run-local local-verify; do
  grep -Eq "^${r}[ :]" "$REPO_ROOT/justfile" && ok "just $r still present" || bad "just $r still present"
done
for r in fast-prepare fast-start-dependencies fast-validate-dependencies fast-status fast-logs fast-stop fast-reset fast-start fast-validate; do
  grep -Eq "^${r}[ :]" "$REPO_ROOT/justfile" && ok "just $r still present" || bad "just $r still present"
done

# --- 11. .gitignore covers generated live-env state -------------------------------
if grep -Eq '^_work-tmp/live-env/$' "$REPO_ROOT/.gitignore"; then
  ok ".gitignore covers _work-tmp/live-env/"
else
  bad ".gitignore covers _work-tmp/live-env/"
fi
if grep -Eq '^_work-tmp/fast-env/$' "$REPO_ROOT/.gitignore"; then
  ok ".gitignore keeps _work-tmp/fast-env/"
else
  bad ".gitignore keeps _work-tmp/fast-env/"
fi
if grep -Eq '^_work-tmp/local/$' "$REPO_ROOT/.gitignore"; then
  ok ".gitignore keeps _work-tmp/local/"
else
  bad ".gitignore keeps _work-tmp/local/"
fi

# --- 12. reset lifecycle + hermeticity ---------------------------------------------
if [ "$CREATED_BY_TEST" = "1" ]; then
  if bash "$HELPER" reset > /dev/null 2>&1 && [ ! -e "$LIVE_DIR" ]; then
    ok "reset removes live-env dir"
  else
    bad "reset removes live-env dir"
  fi
else
  skip "reset-removes-dir (live-env dir pre-existed; leaving untouched)"
fi
ROOT_SUM_AFTER="$(sha256sum "$REPO_ROOT/bfm_status.json" | cut -d' ' -f1)"
LOCAL_SUM_AFTER="$(find "$REPO_ROOT/_work-tmp/local" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1)"
FAST_SUM_AFTER="$(find "$REPO_ROOT/_work-tmp/fast-env" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1)"
[ "$ROOT_SUM_BEFORE" = "$ROOT_SUM_AFTER" ] && ok "repo-root bfm_status.json untouched" || bad "repo-root bfm_status.json untouched"
[ "$LOCAL_SUM_BEFORE" = "$LOCAL_SUM_AFTER" ] && ok "_work-tmp/local untouched" || bad "_work-tmp/local untouched"
[ "$FAST_SUM_BEFORE" = "$FAST_SUM_AFTER" ] && ok "_work-tmp/fast-env untouched" || bad "_work-tmp/fast-env untouched"

echo "---"
echo "self-test: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
