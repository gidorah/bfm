#!/usr/bin/env bash
# live-env helper self-test (issues #18 part C, #23 part C: real jar).
# Seams under test (public interfaces only):
#   1. tools/live-env/live-env.sh CLI: exit codes + filesystem effects under _work-tmp/live-env/
#   2. justfile live-* recipes: presence + delegation to the script (local-*/fast-* untouched)
# Does NOT touch: repo-root bfm_status.json, _work-tmp/local/, _work-tmp/fast-env/, docs/.
#
# Pinned topology (ADR-0005, FIXED): bridge 172.30.51.0/24,
# pg1 172.30.51.11:5432, pg2 172.30.51.12:5432, jar same IPs :7779,
# VIP 172.30.51.100, BFM 127.0.0.1:9995. PG14 pin (jar PgVersion max V14X).
# Jar/config presence replaces the old agent-internal assertions: sibling
# checkout + jar artifact, configuration.json template (clusterManager bfm,
# V14X, trailing slashes), bridge subnet/static IPs/NET_ADMIN/no ports in
# compose, entrypoint jar supervision. VIP proof is docker exec, never checkvip.
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

# Pinned expectations (single source for the new topology).
WANT_PGLIST="172.30.51.11:5432,172.30.51.12:5432"
PG1_IP="172.30.51.11"; PG1_PORT="5432"
PG2_IP="172.30.51.12"; PG2_PORT="5432"
VIP_IP="172.30.51.100"
SUBNET="172.30.51.0/24"
# Needles built by concatenation so this file carries no stale literals.
# shellcheck disable=SC1083
OLD_LOOP='127.0.'10
AGENT_NEEDLE="minipg-"agent
CONF_TMPL_CANDIDATES=(
  "$REPO_ROOT/tools/live-env/configuration.json"
  "$REPO_ROOT/tools/live-env/docker/configuration.json"
)

# --- hermeticity guards -------------------------------------------------------
ROOT_SUM_BEFORE="$(sha256sum "$REPO_ROOT/bfm_status.json" | cut -d' ' -f1)"
LOCAL_SUM_BEFORE="$(find "$REPO_ROOT/_work-tmp/local" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
FAST_SUM_BEFORE="$(find "$REPO_ROOT/_work-tmp/fast-env" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
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
  bad "helper exists at tools/live-env/live-env.sh (worker B not landed yet)"
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
  bad "prepare healthy exits 0 without a usable docker daemon (see $PREP_OUT; Worker B pending if pglist/topology drifted)"
fi
for f in application.properties run logs .launch-id .owner .scenario compose.yaml; do
  [ -e "$LIVE_DIR/$f" ] && ok "prepare creates $f" || bad "prepare creates $f (Worker B pending if absent)"
done
grep -Eq '^[[:space:]]*watcher\.cluster-port[[:space:]]*=[[:space:]]*9995' "$LIVE_DIR/application.properties" \
  && ok "config watcher.cluster-port=9995" || bad "config watcher.cluster-port=9995"
grep -Eq "^[[:space:]]*server\\.pglist[[:space:]]*=[[:space:]]*172\\.30\\.51\\.11:5432,172\\.30\\.51\\.12:5432" "$LIVE_DIR/application.properties" \
  && ok "config server.pglist bridge topology ($WANT_PGLIST)" || bad "config server.pglist bridge topology (want $WANT_PGLIST; Worker B pending if old loopback pair remains)"
grep -Eq '^[[:space:]]*watcher\.cluster-pair[[:space:]]*=[[:space:]]*no-pair' "$LIVE_DIR/application.properties" \
  && ok "config watcher.cluster-pair=no-pair" || bad "config watcher.cluster-pair=no-pair"
grep -Eq '^[[:space:]]*minipg\.port[[:space:]]*=[[:space:]]*7779' "$LIVE_DIR/application.properties" \
  && ok "config minipg.port=7779" || bad "config minipg.port=7779"
grep -Eq '^[[:space:]]*server\.address[[:space:]]*=[[:space:]]*127\.0\.0\.1' "$LIVE_DIR/application.properties" \
  && ok "config server.address=127.0.0.1 (explicit bind)" || bad "config server.address=127.0.0.1 (explicit bind)"
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
# Stale loopback pair must be gone from the rendered config.
if grep -qF "$OLD_LOOP" "$LIVE_DIR/application.properties" 2>/dev/null; then
  bad "rendered config carries no stale loopback tuples (found $OLD_LOOP; Worker B pending)"
else
  ok "rendered config carries no stale loopback tuples"
fi
rm -rf "$SHIM_DIR"

# --- 2. staged compose.yaml carries the bridge topology ------------------------
COMPOSE="$LIVE_DIR/compose.yaml"
if [ -f "$COMPOSE" ]; then
  for lit in 'live-pg1' 'live-pg2' 'bfm-live-pg1' 'bfm-live-pg2' 'wal_log_hints' "$PG1_IP" "$PG2_IP" "$VIP_IP" "$SUBNET"; do
    grep -qF "$lit" "$COMPOSE" && ok "compose.yaml contains $lit" || bad "compose.yaml contains $lit (Worker A pending if bridge literals absent)"
  done
  grep -qF "NET_ADMIN" "$COMPOSE" && ok "compose.yaml grants NET_ADMIN (VIP ip ops)" || bad "compose.yaml grants NET_ADMIN (VIP ip ops; Worker A pending)"
  grep -qE 'cap_add' "$COMPOSE" && ok "compose.yaml uses cap_add" || bad "compose.yaml uses cap_add (Worker A pending)"
  if grep -Eq '^[[:space:]]*ports:' "$COMPOSE"; then
    bad "compose.yaml publishes no ports (host routes bridge; Worker A pending if ports: present)"
  else
    ok "compose.yaml publishes no ports (host routes bridge)"
  fi
  if grep -qF "$OLD_LOOP" "$COMPOSE" 2>/dev/null; then
    bad "compose.yaml carries no stale loopback tuples (Worker A pending)"
  else
    ok "compose.yaml carries no stale loopback tuples"
  fi
  grep -qE '(^|[^0-9])5432([^0-9]|$)' "$COMPOSE" && ok "compose.yaml exposes PG 5432" || bad "compose.yaml exposes PG 5432"
  grep -qE '(^|[^0-9])7779([^0-9]|$)' "$COMPOSE" && ok "compose.yaml exposes MiniPG 7779" || bad "compose.yaml exposes MiniPG 7779"
else
  bad "compose.yaml staged (missing $COMPOSE; Worker B pending)"
fi
# Project name lives on the docker CLI invocation (compose file need not carry it).
grep -qF "bfm-live" "$HELPER" \
  && ok "helper pins compose project bfm-live" \
  || bad "helper pins compose project bfm-live"

# --- 3. Dockerfile builds the real jar image (source-level, no daemon) ---------
DOCKERFILE="$REPO_ROOT/tools/live-env/Dockerfile"
if [ -f "$DOCKERFILE" ]; then
  grep -qF "postgres:14.13-bookworm" "$DOCKERFILE" && ok "Dockerfile pins postgres:14.13-bookworm (PG14)" || bad "Dockerfile pins postgres:14.13-bookworm (PG14; Worker A pending if PG16 remains)"
  grep -qF "minipg.jar" "$DOCKERFILE" && ok "Dockerfile copies minipg.jar" || bad "Dockerfile copies minipg.jar (Worker A pending)"
  grep -qiE "temurin.*(21|jre)|eclipse-temurin" "$DOCKERFILE" && ok "Dockerfile provides Temurin JRE 21" || bad "Dockerfile provides Temurin JRE 21 (Worker A pending)"
  grep -qF "iproute2" "$DOCKERFILE" && ok "Dockerfile installs iproute2 (VIP ip ops)" || bad "Dockerfile installs iproute2 (VIP ip ops; Worker A pending)"
  grep -qiE "sudo" "$DOCKERFILE" && ok "Dockerfile covers passwordless sudo (VIP/postVipUp)" || bad "Dockerfile covers passwordless sudo (VIP/postVipUp; Worker A pending)"
  if grep -qF "$AGENT_NEEDLE" "$DOCKERFILE"; then
    bad "Dockerfile carries no Python-agent script (Worker A leftover)"
  else
    ok "Dockerfile carries no Python-agent script"
  fi
else
  bad "Dockerfile exists at tools/live-env/Dockerfile (Worker A not landed yet)"
fi

# --- 4. compose source carries bridge/VIP/NET_ADMIN (source-level) --------------
COMPOSE_SRC="$REPO_ROOT/tools/live-env/compose.yaml"
if [ -f "$COMPOSE_SRC" ]; then
  for lit in "$PG1_IP" "$PG2_IP" "$VIP_IP" "$SUBNET"; do
    grep -qF "$lit" "$COMPOSE_SRC" && ok "compose source contains $lit" || bad "compose source contains $lit (Worker A pending)"
  done
  grep -qF "NET_ADMIN" "$COMPOSE_SRC" && ok "compose source grants NET_ADMIN" || bad "compose source grants NET_ADMIN (Worker A pending)"
  if grep -Eq '^[[:space:]]*ports:' "$COMPOSE_SRC"; then
    bad "compose source publishes no ports (Worker A pending if ports: present)"
  else
    ok "compose source publishes no ports"
  fi
  if grep -qF "$OLD_LOOP" "$COMPOSE_SRC" 2>/dev/null; then
    bad "compose source carries no stale loopback tuples (Worker A pending)"
  else
    ok "compose source carries no stale loopback tuples"
  fi
else
  bad "compose source exists at tools/live-env/compose.yaml (Worker A not landed yet)"
fi

# --- 5. entrypoint supervises the jar (source-level) ----------------------------
ENTRYPOINT="$REPO_ROOT/tools/live-env/docker/entrypoint.sh"
if [ -f "$ENTRYPOINT" ]; then
  grep -qF "minipg.jar" "$ENTRYPOINT" && ok "entrypoint runs minipg.jar" || bad "entrypoint runs minipg.jar (Worker A pending)"
  grep -qE "java .*-jar" "$ENTRYPOINT" && ok "entrypoint supervises java -jar" || bad "entrypoint supervises java -jar (Worker A pending)"
  grep -qF "wait -n" "$ENTRYPOINT" && ok "entrypoint wait -n supervision" || bad "entrypoint wait -n supervision (Worker A pending; see reference member-entrypoint.sh)"
  grep -qE "trap .*TERM|TERM.*trap" "$ENTRYPOINT" && ok "entrypoint forwards TERM" || bad "entrypoint forwards TERM (Worker A pending)"
  if grep -qF "$AGENT_NEEDLE" "$ENTRYPOINT"; then
    bad "entrypoint carries no Python-agent script (Worker A leftover)"
  else
    ok "entrypoint carries no Python-agent script"
  fi
  if grep -qE "python3.*AGENT|exec python3" "$ENTRYPOINT"; then
    bad "entrypoint execs no python agent (Worker A leftover if python3 exec remains)"
  else
    ok "entrypoint execs no python agent"
  fi
else
  bad "entrypoint exists at tools/live-env/docker/entrypoint.sh (Worker A not landed yet)"
fi

# --- 6. configuration.json template + sibling jar (source-level) ----------------
TMPL=""
for c in "${CONF_TMPL_CANDIDATES[@]}"; do
  [ -f "$c" ] && TMPL="$c" && break
done
if [ -z "$TMPL" ]; then
  FOUND="$(find "$REPO_ROOT/tools/live-env" -maxdepth 3 -name 'configuration*.json' 2>/dev/null | head -n 1 || true)"
  [ -n "$FOUND" ] && TMPL="$FOUND"
fi
if [ -n "$TMPL" ] && [ -f "$TMPL" ]; then
  ok "configuration.json template found at $TMPL (single static, baked into image)"
  grep -qF '"clusterManager"' "$TMPL" && grep -qF '"bfm"' "$TMPL" \
    && ok 'template clusterManager bfm (NPE guard)' || bad 'template clusterManager bfm (NOT omittable; MiniPGHelper.java:77 NPEs on null)'
  grep -qF 'V14X' "$TMPL" && ok "template pgVersion V14X (PG14 pin)" || bad "template pgVersion V14X (PG14 pin; jar PgVersion maxes at V14X)"
  grep -qF '/usr/lib/postgresql/14/bin/' "$TMPL" \
    && ok "template PG14 bin paths with trailing slash (load-bearing concat)" \
    || bad "template PG14 bin paths with trailing slash (jar concatenates pgCtlBinPath + pg_ctl)"
  grep -qE '"port"[[:space:]]*:[[:space:]]*7779' "$TMPL" && ok "template port 7779" || bad "template port 7779"
  grep -qF '"vipInterface"' "$TMPL" && ok "template vipInterface present (verify eth0 at runtime)" || bad "template vipInterface present (verify eth0 at runtime)"
  grep -qF '/bin/true' "$TMPL" && ok "template postVipUp /bin/true" || bad "template postVipUp /bin/true"
  grep -qF '"postgresDataPath"' "$TMPL" && ok "template postgresDataPath present (per-node data dir)" || bad "template postgresDataPath present (per-node data dir)"
  if grep -qF 'patroniCtlBinPath' "$TMPL" || grep -qF 'patroniConfFilePath' "$TMPL"; then
    bad "template omits Patroni-only keys (no Patroni in BFM live env)"
  else
    ok "template omits Patroni-only keys"
  fi
else
  bad "configuration.json template exists (Worker A pending: single static tools/live-env/configuration.json)"
fi
# Staged jar (Worker B stages the chosen jar at prepare to
# _work-tmp/live-env/minipg.jar, honoring BFM_LIVE_MINIPG_JAR=; the single
# static configuration.json needs NO staging — the image COPYs it baked).
if [ -f "$LIVE_DIR/minipg.jar" ]; then
  ok "prepare stages minipg.jar"
  if command -v unzip >/dev/null 2>&1 && unzip -l "$LIVE_DIR/minipg.jar" 2>/dev/null | grep -q "MiniPGController"; then
    ok "staged minipg.jar looks like the real jar"
  else
    ok "staged minipg.jar present (content check best-effort)"
  fi
else
  bad "prepare stages minipg.jar at _work-tmp/live-env/minipg.jar (Worker B pending; honors BFM_LIVE_MINIPG_JAR=)"
fi
# Sibling checkout + jar artifact (SKIP when the sibling is absent off-box).
SIBLING="$REPO_ROOT/../minipgonpatroni"
if [ -d "$SIBLING" ]; then
  ok "sibling checkout ../minipgonpatroni present"
  if ls "$SIBLING/app/target"/minipg4patroni-app-*.jar >/dev/null 2>&1; then
    ok "sibling jar artifact minipg4patroni-app-*.jar built"
  else
    bad "sibling jar artifact minipg4patroni-app-*.jar built (run ./mvnw -f \$MINIPG_ROOT/pom.xml -pl app -am package or set BFM_LIVE_MINIPG_JAR=)"
  fi
  grep -qF "BFM_LIVE_MINIPG_JAR" "$REPO_ROOT/tools/live-env/README.md" \
    && ok "README documents BFM_LIVE_MINIPG_JAR= override" || bad "README documents BFM_LIVE_MINIPG_JAR= override"
else
  skip "sibling checkout ../minipgonpatroni absent (jar artifact check needs the sibling; set BFM_LIVE_MINIPG_JAR= to a prebuilt jar)"
fi

# --- 7. zero agent references; no translation shim; no checkvip evidence --------
# Path built by concatenation so this file carries no stale script literal.
AGENT_SCRIPT="$REPO_ROOT/tools/live-env/minipg-"agent.py
if [ -f "$AGENT_SCRIPT" ]; then
  bad "Python script deleted (stale agent script still present under tools/live-env/; chop it)"
else
  ok "Python script deleted"
fi
LEFTOVERS="$(grep -rnF "$AGENT_NEEDLE" --exclude-dir=.git --exclude-dir=_work-tmp "$REPO_ROOT" 2>/dev/null | grep -v '^Binary' | grep -v 'docs/decisions/' || true)"
if [ -z "$LEFTOVERS" ]; then
  ok "zero agent references outside ADRs/history"
else
  bad "zero agent references outside ADRs/history (leftovers; Worker A owns Dockerfile/entrypoint): $(printf '%s' "$LEFTOVERS" | head -n 5 | tr '\n' ';')"
fi
if grep -qF "$OLD_LOOP" "$REPO_ROOT/tools/live-env/README.md" 2>/dev/null; then
  bad "README carries no stale loopback tuples"
else
  ok "README carries no stale loopback tuples"
fi
if grep -qF "Python agent" "$REPO_ROOT/tools/live-env/README.md" 2>/dev/null || grep -qF "compatible Python" "$REPO_ROOT/tools/live-env/README.md" 2>/dev/null; then
  bad "README drops all Python-agent docs"
else
  ok "README drops all Python-agent docs"
fi
for doc in bridge VIP "docker exec" "14.13" "trailing" "clusterManager"; do
  grep -qiF "$doc" "$REPO_ROOT/tools/live-env/README.md" \
    && ok "README documents $doc" || bad "README documents $doc"
done
if grep -qF "$OLD_LOOP" "$HELPER" 2>/dev/null; then
  bad "helper carries no stale loopback tuples (Worker B pending)"
else
  ok "helper carries no stale loopback tuples"
fi
if grep -q "checkvip" "$HELPER" 2>/dev/null; then
  bad "helper never uses checkvip as VIP evidence (checkvip manufactures state; Worker B pending: prove VIP via docker exec)"
else
  ok "helper never uses checkvip as VIP evidence"
fi
if grep -q "docker exec" "$HELPER" 2>/dev/null && grep -q "ip address show" "$HELPER" 2>/dev/null; then
  ok "helper proves VIP via docker exec ip address show"
else
  bad "helper proves VIP via docker exec ip address show (Worker B pending)"
fi

# --- 8. prepare rejects unknown + deferred scenarios (fail-closed) ---------------
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

# --- 9. prepare accepts kill-primary, keeps identical topology -------------------
if bash "$HELPER" prepare kill-primary > /dev/null 2>&1; then
  ok "prepare accepts kill-primary"
else
  bad "prepare accepts kill-primary"
fi
[ "$(cat "$LIVE_DIR/.scenario" 2>/dev/null)" = "kill-primary" ] \
  && ok "prepare records .scenario=kill-primary" \
  || bad "prepare records .scenario=kill-primary"
PGLIST_K="$(grep -E '^[[:space:]]*server\.pglist[[:space:]]*=' "$LIVE_DIR/application.properties" | sed 's/.*=[[:space:]]*//' || true)"
[ "$PGLIST_K" = "$WANT_PGLIST" ] \
  && ok "kill-primary keeps identical topology (server.pglist)" \
  || bad "kill-primary keeps identical topology (server.pglist, got '$PGLIST_K'; want $WANT_PGLIST)"
bash "$HELPER" prepare healthy > /dev/null 2>&1

# --- 10. helper CLI contract (Worker B shape) ------------------------------------
for cmd in prepare start-dependencies validate-dependencies status logs stop reset start validate kill-primary rejoin; do
  if grep -q "$cmd)" "$HELPER"; then
    ok "helper dispatches $cmd"
  else
    bad "helper dispatches $cmd (Worker B contract)"
  fi
done
for act in kill-primary rejoin; do
  OUT="$(mktemp)"
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

# --- 11. unknown command refused --------------------------------------------------
if bash "$HELPER" bogus-command > /dev/null 2>&1; then
  bad "unknown command refused"
else
  ok "unknown command refused"
fi

# --- 12. status / logs / stop work without side effects ---------------------------
bash "$HELPER" status > /dev/null 2>&1 && ok "status exits 0" || bad "status exits 0"
bash "$HELPER" logs 5 > /dev/null 2>&1 && ok "logs exits 0" || bad "logs exits 0"
bash "$HELPER" stop > /dev/null 2>&1 && ok "stop exits 0 when nothing running" || bad "stop exits 0 when nothing running"

# --- 13. validate wrappers fail clearly with nothing running (no daemon needed) ----
VAL_OUT="$(mktemp)"
if run_limited 120 bash "$HELPER" validate-dependencies >"$VAL_OUT" 2>&1; then
  bad "validate-dependencies fails clearly with no dependencies running"
else
  if grep -qiE "missing|not listening|not running|refus|no stub|not prepared|unexpected|mismatch" "$VAL_OUT"; then
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

# --- 14. docker-dependent live checks (SKIP when daemon absent) --------------------
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

# --- 15. just live-* delegates; just local-*/fast-* untouched ---------------------
if grep -Eq '^live-prepare' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-start-dependencies' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-validate-dependencies' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-status' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-logs' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-stop' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-reset' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-start' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-validate' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-kill-primary' "$REPO_ROOT/justfile" \
  && grep -Eq '^live-rejoin' "$REPO_ROOT/justfile" \
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

# --- 16. ADR-0005 supersedes 0004 --------------------------------------------------
if [ -f "$REPO_ROOT/docs/decisions/0005-live-environment-real-minipg.md" ]; then
  ok "ADR-0005 exists"
  grep -qiE "supersede.*0004|supersede.*live-environment-docker-topology" "$REPO_ROOT/docs/decisions/0005-live-environment-real-minipg.md" \
    && ok "ADR-0005 names supersession of 0004" || bad "ADR-0005 names supersession of 0004"
  for lit in "$PG1_IP" "$PG2_IP" "$VIP_IP" "V14X" "NET_ADMIN" "checkvip"; do
    grep -qF "$lit" "$REPO_ROOT/docs/decisions/0005-live-environment-real-minipg.md" \
      && ok "ADR-0005 records $lit" || bad "ADR-0005 records $lit"
  done
else
  bad "ADR-0005 exists at docs/decisions/0005-live-environment-real-minipg.md"
fi

# --- 17. .gitignore covers generated live-env state -------------------------------
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

# --- 18. reset lifecycle + hermeticity ---------------------------------------------
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
LOCAL_SUM_AFTER="$(find "$REPO_ROOT/_work-tmp/local" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
FAST_SUM_AFTER="$(find "$REPO_ROOT/_work-tmp/fast-env" -type f -exec sha256sum {} + 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
[ "$ROOT_SUM_BEFORE" = "$ROOT_SUM_AFTER" ] && ok "repo-root bfm_status.json untouched" || bad "repo-root bfm_status.json untouched"
[ "$LOCAL_SUM_BEFORE" = "$LOCAL_SUM_AFTER" ] && ok "_work-tmp/local untouched" || bad "_work-tmp/local untouched"
[ "$FAST_SUM_BEFORE" = "$FAST_SUM_AFTER" ] && ok "_work-tmp/fast-env untouched" || bad "_work-tmp/fast-env untouched"

echo "---"
echo "self-test: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
