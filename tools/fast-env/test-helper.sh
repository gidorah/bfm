#!/usr/bin/env bash
# fast-env helper self-test (milestone 1).
# Seams under test (public interfaces only):
#   1. tools/fast-env/fast-env.sh CLI: exit codes + filesystem effects under _work-tmp/fast-env/
#   2. justfile fast-* recipes: presence + delegation to the script (local-* untouched)
# Does NOT touch: repo-root bfm_status.json, _work-tmp/local/, fixtures, dev/fast-env, pgwire stub,
#   dev/fast-env template contents, .vscode/launch.json, docs/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/tools/fast-env/fast-env.sh"
FAST_DIR="$REPO_ROOT/_work-tmp/fast-env"
TOOL_CACHE="$REPO_ROOT/_work-tmp/fast-env-tool-cache"
WIREMOCK_VERSION="3.9.1"
WIREMOCK_SHA256="723a880d50d3b0a145af0df07e578c2cb85e77feb2231e6991c9a1366926912c"
WIREMOCK_JAR="$TOOL_CACHE/wiremock-standalone-${WIREMOCK_VERSION}.jar"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- hermeticity guards -------------------------------------------------------
ROOT_SUM_BEFORE="$(sha256sum "$REPO_ROOT/bfm_status.json" | cut -d' ' -f1)"
LOCAL_SUM_BEFORE="$(find "$REPO_ROOT/_work-tmp/local" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1)"
CREATED_BY_TEST=0
[ -e "$FAST_DIR" ] || CREATED_BY_TEST=1

cleanup_listeners() { # kill fake stub listeners started by this test
  if [ -f "$FAST_DIR/.selftest-pids" ]; then
    while read -r p; do kill "$p" 2>/dev/null || true; done < "$FAST_DIR/.selftest-pids"
    rm -f "$FAST_DIR/.selftest-pids"
  fi
}
helper_stop() { bash "$HELPER" stop > /dev/null 2>&1 || true; }
trap 'cleanup_listeners; helper_stop' EXIT

tuple_up() { python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); s.connect((sys.argv[1], int(sys.argv[2])))" "$1" "$2" 2>/dev/null; }
http_code() { # http_code <url> [user:pass]: proxy-bypassed status (000 on failure)
  local url="$1" creds="${2:-}" args=(--noproxy '*' --max-time 5 -s -o /dev/null -w '%{http_code}')
  [ -n "$creds" ] && args+=(-u "$creds")
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    curl "${args[@]}" "$url" 2>/dev/null || echo "000"
}

# --- 1. prepare healthy creates expected layout -------------------------------
PREP_OUT="$(mktemp)"
if bash "$HELPER" prepare healthy >"$PREP_OUT" 2>&1; then
  for f in application.properties run logs .launch-id .owner .scenario; do
    [ -e "$FAST_DIR/$f" ] && ok "prepare creates $f" || bad "prepare creates $f"
  done
  grep -Eq '^[[:space:]]*watcher\.cluster-port[[:space:]]*=[[:space:]]*9995' "$FAST_DIR/application.properties" \
    && ok "config watcher.cluster-port=9995" || bad "config watcher.cluster-port=9995"
  grep -Eq '^[[:space:]]*server\.pglist[[:space:]]*=[[:space:]]*127\.0\.10\.11:5432,127\.0\.10\.12:5433' "$FAST_DIR/application.properties" \
    && ok "config server.pglist loopback topology" || bad "config server.pglist loopback topology"
  grep -Eq '^[[:space:]]*server\.address[[:space:]]*=[[:space:]]*127\.0\.0\.1' "$FAST_DIR/application.properties" \
    && ok "config server.address explicit bind" || bad "config server.address explicit bind"
  grep -Eq '^[[:space:]]*watcher\.cluster-pair[[:space:]]*=[[:space:]]*no-pair' "$FAST_DIR/application.properties" \
    && ok "config watcher.cluster-pair=no-pair" || bad "config watcher.cluster-pair=no-pair"
  grep -Eq '^[[:space:]]*minipg\.port[[:space:]]*=[[:space:]]*7779' "$FAST_DIR/application.properties" \
    && ok "config minipg.port=7779" || bad "config minipg.port=7779"
  # Fixed test-only credentials bfm/bfm (no per-run secrets).
  for key in 'server\.pguser' 'server\.pgpassword' 'minipg\.username' 'minipg\.password'; do
    VAL="$(grep -E "^[[:space:]]*$key[[:space:]]*=" "$FAST_DIR/application.properties" | sed 's/.*=[[:space:]]*//' | tail -n 1)"
    if [ "$VAL" = "bfm" ]; then
      ok "config $key=bfm (fixed test-only creds)"
    else
      bad "config $key=bfm (fixed test-only creds, got '$VAL')"
    fi
  done
else
  bad "prepare healthy exits 0 (see $PREP_OUT)"
fi

# --- 2. prepare rejects non-healthy scenarios ---------------------------------
if bash "$HELPER" prepare bogus-scenario > /dev/null 2>&1; then
  bad "prepare rejects unknown scenario"
else
  ok "prepare rejects unknown scenario"
fi

# --- 3. WireMock tool cache (pinned + verified, survives reset) ---------------
if [ -f "$WIREMOCK_JAR" ]; then
  ok "prepare populates WireMock tool cache"
else
  bad "prepare populates WireMock tool cache ($WIREMOCK_JAR missing)"
fi
if [ -f "$WIREMOCK_JAR" ] && [ "$(sha256sum "$WIREMOCK_JAR" | awk '{ print $1 }')" = "$WIREMOCK_SHA256" ]; then
  ok "WireMock cache checksum matches pinned $WIREMOCK_VERSION"
else
  bad "WireMock cache checksum matches pinned $WIREMOCK_VERSION"
fi
case "$(realpath -m -- "$TOOL_CACHE")" in
  "$REPO_ROOT/_work-tmp/fast-env-tool-cache"*) ok "WireMock cache lives outside run dir";;
  *) bad "WireMock cache lives outside run dir";;
esac
CACHE_CANON="$(realpath -m -- "$TOOL_CACHE")"
FAST_CANON="$(realpath -m -- "$FAST_DIR")"
case "$CACHE_CANON" in
  "$FAST_CANON"/*) bad "WireMock cache outside FAST_DIR (reset keeps it)";;
  *) ok "WireMock cache outside FAST_DIR (reset keeps it)";;
esac
if [ -f "$WIREMOCK_JAR" ] && [ ! -L "$WIREMOCK_JAR" ]; then
  ok "WireMock cache jar is not a symlink"
else
  bad "WireMock cache jar is not a symlink"
fi

# --- 4. start-dependencies launches pgwire + per-IP WireMock JVMs --------------
STUB_OUT="$(mktemp)"
if bash "$HELPER" start-dependencies >"$STUB_OUT" 2>&1; then
  ok "start-dependencies exits 0 with pinned WireMock"
else
  bad "start-dependencies exits 0 with pinned WireMock (see $STUB_OUT)"
fi
if tuple_up 127.0.10.11 5432 && tuple_up 127.0.10.12 5433; then
  ok "start-dependencies launched helper-owned pgwire stubs"
else
  bad "start-dependencies launched helper-owned pgwire stubs"
fi
if tuple_up 127.0.10.11 7779 && tuple_up 127.0.10.12 7779; then
  ok "start-dependencies launched per-IP WireMock JVMs"
else
  bad "start-dependencies launched per-IP WireMock JVMs"
fi
MUSER="$(grep -E '^[[:space:]]*minipg\.username[[:space:]]*=' "$FAST_DIR/application.properties" | sed 's/.*=[[:space:]]*//')"
MPASS="$(grep -E '^[[:space:]]*minipg\.password[[:space:]]*=' "$FAST_DIR/application.properties" | sed 's/.*=[[:space:]]*//')"
C1="$(http_code "http://127.0.10.11:7779/pgstatus" "$MUSER:$MPASS")"
C2="$(http_code "http://127.0.10.12:7779/pgstatus" "$MUSER:$MPASS")"
if [ -n "$C1" ] && [ "$C1" != "000" ] && [ -n "$C2" ] && [ "$C2" != "000" ]; then
  ok "WireMock minipg answers HTTP per node ($C1/$C2)"
else
  bad "WireMock minipg answers HTTP per node ($C1/$C2)"
fi
if [ -d "$FAST_DIR/wiremock-127.0.10.11/mappings" ] && [ -d "$FAST_DIR/wiremock-127.0.10.12/mappings" ] \
  && [ -n "$(ls -A "$FAST_DIR/wiremock-127.0.10.11/mappings" 2>/dev/null)" ]; then
  ok "start-dependencies stages WireMock mappings per IP"
else
  bad "start-dependencies stages WireMock mappings per IP"
fi
bash "$HELPER" stop > /dev/null 2>&1
DEADLINE=$((SECONDS + 25))
while (( SECONDS < DEADLINE )) && { tuple_up 127.0.10.11 5432 || tuple_up 127.0.10.12 5433 || tuple_up 127.0.10.11 7779 || tuple_up 127.0.10.12 7779; }; do sleep 0.5; done
if tuple_up 127.0.10.11 5432 || tuple_up 127.0.10.12 5433 || tuple_up 127.0.10.11 7779 || tuple_up 127.0.10.12 7779; then
  bad "stop tears down helper-owned stubs (pgwire + WireMock)"
else
  ok "stop tears down helper-owned stubs (pgwire + WireMock)"
fi

# --- 4b. stop works from a different process group -----------------------------
# Each just recipe runs in its own shell/pgid; ownership must describe the
# launching shell (refreshed by start-dependencies), not the caller.
bash "$HELPER" start-dependencies > /dev/null 2>&1
OWNER_BEFORE="$(grep -E '^pgid=' "$FAST_DIR/.owner" 2>/dev/null | cut -d= -f2-)"
# Pure-adopt re-run (nothing to launch) must preserve the existing owner.
if setsid bash "$HELPER" start-dependencies > /dev/null 2>&1; then
  OWNER_AFTER="$(grep -E '^pgid=' "$FAST_DIR/.owner" 2>/dev/null | cut -d= -f2-)"
  if [ -n "$OWNER_BEFORE" ] && [ "$OWNER_BEFORE" = "$OWNER_AFTER" ]; then
    ok "adopt-only start preserves ownership"
  else
    bad "adopt-only start preserves ownership (before=$OWNER_BEFORE after=$OWNER_AFTER)"
  fi
else
  bad "adopt-only start preserves ownership (adopt re-run failed)"
fi
if setsid bash "$HELPER" stop > /dev/null 2>&1; then
  DEADLINE=$((SECONDS + 25))
  while (( SECONDS < DEADLINE )) && { tuple_up 127.0.10.11 5432 || tuple_up 127.0.10.12 5433 || tuple_up 127.0.10.11 7779 || tuple_up 127.0.10.12 7779; }; do sleep 0.5; done
  if tuple_up 127.0.10.11 5432 || tuple_up 127.0.10.12 5433 || tuple_up 127.0.10.11 7779 || tuple_up 127.0.10.12 7779; then
    bad "stop works across process groups (stubs still up)"
  else
    ok "stop works across process groups"
  fi
else
  bad "stop works across process groups (setsid stop refused)"
fi

# --- 4c. IPv4-mapped IPv6 detection (Java dual-stack regression) ---------------
# Java binds dual-stack: ss shows [::ffff:127.0.0.1]:9995, which tuple
# detection must normalize to 127.0.0.1 (validate went red on this).
SS_FIX_DIR="$(mktemp -d)"
cat >"$SS_FIX_DIR/ss" <<'EOF'
#!/bin/bash
printf 'LISTEN 0 128 [::ffff:127.0.0.1]:9995 *:* users:(("java",pid=99999,fd=1))\n'
EOF
chmod +x "$SS_FIX_DIR/ss"
if SS_BIN="$SS_FIX_DIR/ss" bash "$HELPER" status 2>/dev/null | grep -q "tuple 127.0.0.1:9995: LISTENING"; then
  ok "tuple detection sees Java-mapped [::ffff:127.0.0.1]:9995"
else
  bad "tuple detection sees Java-mapped [::ffff:127.0.0.1]:9995"
fi
rm -rf "$SS_FIX_DIR"

# --- 5. status / logs / stop work without side effects ------------------------
bash "$HELPER" status > /dev/null 2>&1 && ok "status exits 0" || bad "status exits 0"
bash "$HELPER" logs 5 > /dev/null 2>&1 && ok "logs exits 0" || bad "logs exits 0"
bash "$HELPER" stop > /dev/null 2>&1 && ok "stop exits 0 when nothing running" || bad "stop exits 0 when nothing running"

# --- 6. validate-dependencies fails clearly with no stubs and no BFM ----------
VAL_OUT="$(mktemp)"
if bash "$HELPER" validate-dependencies >"$VAL_OUT" 2>&1; then
  bad "validate-dependencies fails clearly with no stubs running"
else
  if grep -qiE "missing|not listening|not running|refus|no stub" "$VAL_OUT"; then
    ok "validate-dependencies fails clearly with no stubs running"
  else
    bad "validate-dependencies fails clearly with no stubs running (no clear message)"
  fi
fi

# --- 7. validate wrapper requires helper-owned BFM ----------------------------
if bash "$HELPER" validate > /dev/null 2>&1; then
  bad "validate refuses without helper-owned BFM"
else
  ok "validate refuses without helper-owned BFM"
fi

# --- 8. unknown command refused ------------------------------------------------
if bash "$HELPER" bogus-command > /dev/null 2>&1; then
  bad "unknown command refused"
else
  ok "unknown command refused"
fi

# --- 9. env override refusals --------------------------------------------------
if env JAVA_TOOL_OPTIONS="-Dfoo=bar" bash "$HELPER" prepare healthy > /dev/null 2>&1; then
  bad "prepare refuses JAVA_TOOL_OPTIONS override"
else
  ok "prepare refuses JAVA_TOOL_OPTIONS override"
fi
if env SPRING_CONFIG_LOCATION="/etc/bfm/bfmwatcher/application.properties" bash "$HELPER" prepare healthy > /dev/null 2>&1; then
  bad "prepare refuses deployment-path config override"
else
  ok "prepare refuses deployment-path config override"
fi

# --- 10. reset refuses while IDE-owned BFM marker active -----------------------
mkdir -p "$FAST_DIR"
touch "$FAST_DIR/.ide-bfm-active"
if bash "$HELPER" reset > /dev/null 2>&1; then
  bad "reset refuses while IDE-owned BFM marker active"
  rm -f "$FAST_DIR/.ide-bfm-active"
else
  ok "reset refuses while IDE-owned BFM marker active"
  rm -f "$FAST_DIR/.ide-bfm-active"
fi

# --- 11. deps-present but BFM absent must FAIL (no deps-only green) -------------
python3 - "$FAST_DIR/.selftest-pids" <<'EOF'
import socket, subprocess, sys, os
pidfile = sys.argv[1]
targets = [("127.0.10.11", 5432), ("127.0.10.12", 5433),
           ("127.0.10.11", 7779), ("127.0.10.12", 7779)]
procs = []
for ip, port in targets:
    p = subprocess.Popen(
        ["python3", "-c",
         "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); "
         f"s.bind(('{ip}', {port})); s.listen(5); "
         "import time; time.sleep(120)"])
    procs.append(p)
with open(pidfile, "w") as f:
    for p in procs:
        f.write(str(p.pid) + "\n")
EOF
sleep 1
CHAIN_OUT="$(mktemp)"
bash "$HELPER" prepare healthy > /dev/null 2>&1
bash "$HELPER" start-dependencies >"$CHAIN_OUT" 2>&1
if bash "$HELPER" validate-dependencies >>"$CHAIN_OUT" 2>&1; then
  bad "validate-dependencies requires BFM evidence (fails when BFM absent)"
else
  if grep -qiE "BFM.*not listening|BFM evidence|start.*F5|via.*start" "$CHAIN_OUT"; then
    ok "validate-dependencies requires BFM evidence (fails when BFM absent)"
  else
    bad "validate-dependencies requires BFM evidence (fails when BFM absent; no clear BFM message, see $CHAIN_OUT)"
  fi
fi
cleanup_listeners

# --- 12. PID/group ownership enforced on stop/reset ----------------------------
if grep -Eq '^dir=' "$FAST_DIR/.owner" && grep -Eq '^pid=[0-9]+' "$FAST_DIR/.owner" \
  && grep -Eq '^pgid=[0-9]+' "$FAST_DIR/.owner"; then
  ok "owner file records dir/pid/pgid"
else
  bad "owner file records dir/pid/pgid"
fi
cp "$FAST_DIR/.owner" "$FAST_DIR/.owner.bak"
# Tampered dir must be refused.
sed -i 's|^dir=.*|dir=/tmp/foreign|' "$FAST_DIR/.owner"
if bash "$HELPER" stop > /dev/null 2>&1; then
  bad "stop enforces dir ownership"
else
  ok "stop enforces dir ownership"
fi
if bash "$HELPER" reset > /dev/null 2>&1; then
  bad "reset enforces dir ownership"
else
  ok "reset enforces dir ownership"
fi
cp "$FAST_DIR/.owner.bak" "$FAST_DIR/.owner"
# Invalid pgid must be refused (pgid is checked, not just stored).
sed -i 's|^pgid=.*|pgid=bogus|' "$FAST_DIR/.owner"
if bash "$HELPER" stop > /dev/null 2>&1; then
  bad "stop enforces pgid ownership"
else
  ok "stop enforces pgid ownership"
fi
if bash "$HELPER" reset > /dev/null 2>&1; then
  bad "reset enforces pgid ownership"
else
  ok "reset enforces pgid ownership"
fi
cp "$FAST_DIR/.owner.bak" "$FAST_DIR/.owner"
rm -f "$FAST_DIR/.owner.bak"
# Restored owner must work again.
if bash "$HELPER" stop > /dev/null 2>&1; then
  ok "stop succeeds with valid ownership"
else
  bad "stop succeeds with valid ownership"
fi
# Foreign helper pid outside the owner group must be refused (fail-closed, not killed).
sleep 60 &
FOREIGN_PID=$!
FOREIGN_PGID="$(ps -o pgid= -p "$FOREIGN_PID" | tr -d ' ')"
OWNER_PGID="$(grep -E '^pgid=' "$FAST_DIR/.owner" | cut -d= -f2-)"
if [ "$FOREIGN_PGID" = "$OWNER_PGID" ]; then
  # Same group by construction (same session); simulate foreign by tampering owner pgid.
  cp "$FAST_DIR/.owner" "$FAST_DIR/.owner.bak2"
  sed -i 's|^pgid=.*|pgid=999999|' "$FAST_DIR/.owner"
  echo "$FOREIGN_PID" > "$FAST_DIR/.pids"
  if bash "$HELPER" stop > /dev/null 2>&1; then
    bad "stop refuses foreign-group pid"
  else
    ok "stop refuses foreign-group pid"
  fi
  if kill -0 "$FOREIGN_PID" 2>/dev/null; then
    ok "stop does not kill foreign-group pid (fail-closed)"
  else
    bad "stop does not kill foreign-group pid (fail-closed)"
  fi
  kill "$FOREIGN_PID" 2>/dev/null || true
  wait "$FOREIGN_PID" 2>/dev/null || true
  rm -f "$FAST_DIR/.pids"
  cp "$FAST_DIR/.owner.bak2" "$FAST_DIR/.owner"
  rm -f "$FAST_DIR/.owner.bak2"
else
  echo "$FOREIGN_PID" > "$FAST_DIR/.pids"
  if bash "$HELPER" stop > /dev/null 2>&1; then
    bad "stop refuses foreign-group pid"
  else
    ok "stop refuses foreign-group pid"
  fi
  if kill -0 "$FOREIGN_PID" 2>/dev/null; then
    ok "stop does not kill foreign-group pid (fail-closed)"
  else
    bad "stop does not kill foreign-group pid (fail-closed)"
  fi
  kill "$FOREIGN_PID" 2>/dev/null || true
  wait "$FOREIGN_PID" 2>/dev/null || true
  rm -f "$FAST_DIR/.pids"
fi

# --- 13. redaction: credential-bearing forms redacted (fail-closed) ------------
# Fixed test-only creds are bfm/bfm, so the literal value is public and
# ubiquitous in logs; what must never leak is its secret-bearing form, the
# Basic blob YmZtOmJmbQ== (bfm:bfm).
BASIC_BLOB="YmZtOmJmbQ=="
if grep -rqF -- "$BASIC_BLOB" "$FAST_DIR/logs" 2>/dev/null; then
  bad "stored logs redacted before storage"
else
  ok "stored logs redacted before storage"
fi
LOGS_OUT="$(mktemp)"
if bash "$HELPER" logs 50 >"$LOGS_OUT" 2>&1; then
  if grep -qF -- "$BASIC_BLOB" "$LOGS_OUT" 2>/dev/null; then
    bad "logs output redacted"
  else
    ok "logs output redacted"
  fi
else
  bad "logs output redacted (logs command failed)"
fi

# --- 13b. leak-scan: blobs fail, innocent literals pass ------------------------
# With fixed bfm/bfm creds the literal is public; only the Basic blob form
# must never be stored (validate's tripwire uses the same scanner).
LEAK_FIX="$(mktemp -d)"
printf 'this is the active bfm pair\nCluster Status is HEALTHY\n' >"$LEAK_FIX/clean.log"
printf 'Authorization: Basic YmZtOmJmbQ==\n' >"$LEAK_FIX/dirty.log"
if bash "$REPO_ROOT/tools/fast-env/leak-scan.sh" "YmZtOmJmbQ==" "$LEAK_FIX/clean.log" 2>/dev/null; then
  ok "leak-scan passes innocent log text"
else
  bad "leak-scan passes innocent log text"
fi
if bash "$REPO_ROOT/tools/fast-env/leak-scan.sh" "YmZtOmJmbQ==" "$LEAK_FIX/dirty.log" 2>/dev/null; then
  bad "leak-scan catches credential blob"
else
  ok "leak-scan catches credential blob"
fi
rm -rf "$LEAK_FIX"

# --- 14. just fast-* delegates; just local-* untouched -------------------------
if grep -Eq '^fast-prepare' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-start-dependencies' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-validate-dependencies' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-status' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-logs' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-stop' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-reset' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-start' "$REPO_ROOT/justfile" \
  && grep -Eq '^fast-validate' "$REPO_ROOT/justfile" \
  && grep -q 'tools/fast-env/fast-env.sh' "$REPO_ROOT/justfile"; then
  ok "just fast-* recipes delegate to helper"
else
  bad "just fast-* recipes delegate to helper"
fi
for r in local-prepare local-reset local-status local-logs run-local local-verify; do
  grep -Eq "^${r}[ :]" "$REPO_ROOT/justfile" && ok "just $r still present" || bad "just $r still present"
done

# --- 15. .gitignore covers generated fast-env state ---------------------------
if grep -Eq '^_work-tmp/fast-env/$' "$REPO_ROOT/.gitignore"; then
  ok ".gitignore covers _work-tmp/fast-env/"
else
  bad ".gitignore covers _work-tmp/fast-env/"
fi
if grep -Eq '^_work-tmp/local/$' "$REPO_ROOT/.gitignore"; then
  ok ".gitignore keeps _work-tmp/local/"
else
  bad ".gitignore keeps _work-tmp/local/"
fi

# --- 16. reset lifecycle + hermeticity -----------------------------------------
if [ "$CREATED_BY_TEST" = "1" ]; then
  if bash "$HELPER" reset > /dev/null 2>&1 && [ ! -e "$FAST_DIR" ]; then
    ok "reset removes fast-env dir"
  else
    bad "reset removes fast-env dir"
  fi
else
  echo "SKIP: reset-removes-dir (fast-env dir pre-existed; leaving untouched)"
fi
if [ -f "$WIREMOCK_JAR" ] && [ "$(sha256sum "$WIREMOCK_JAR" | awk '{ print $1 }')" = "$WIREMOCK_SHA256" ]; then
  ok "reset keeps WireMock tool cache"
else
  bad "reset keeps WireMock tool cache"
fi
ROOT_SUM_AFTER="$(sha256sum "$REPO_ROOT/bfm_status.json" | cut -d' ' -f1)"
LOCAL_SUM_AFTER="$(find "$REPO_ROOT/_work-tmp/local" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1)"
[ "$ROOT_SUM_BEFORE" = "$ROOT_SUM_AFTER" ] && ok "repo-root bfm_status.json untouched" || bad "repo-root bfm_status.json untouched"
[ "$LOCAL_SUM_BEFORE" = "$LOCAL_SUM_AFTER" ] && ok "_work-tmp/local untouched" || bad "_work-tmp/local untouched"

echo "---"
echo "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
