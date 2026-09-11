set shell := ["bash", "-euo", "pipefail", "-c"]

mvn := "./mvnw"

default:
    @just --list

test:
    {{ mvn }} -f app/pom.xml test

build:
    {{ mvn }} -f app/pom.xml clean package

package-all:
    {{ mvn }} clean package

local_dir := justfile_directory() + "/_work-tmp/local"
config := local_dir + "/application.properties"
run_dir := local_dir + "/run"
state := run_dir + "/bfm_status.json"
log_file := local_dir + "/logs/app.log"

local-prepare:
    @mkdir -p "{{ run_dir }}" "{{ local_dir }}/logs"
    @if [ ! -f "{{ config }}" ]; then cp "{{ justfile_directory() }}/dev/local/application.properties" "{{ config }}"; echo "COPY dev/local/application.properties -> {{ config }}"; else echo "KEEP {{ config }}"; fi
    @if [ ! -f "{{ state }}" ]; then cp "{{ justfile_directory() }}/dev/local/bfm_status.json.seed" "{{ state }}"; echo "COPY dev/local/bfm_status.json.seed -> {{ state }}"; else echo "KEEP {{ state }}"; fi
    @echo "watcher.cluster-port=$(grep -E '^[[:space:]]*watcher\.cluster-port[[:space:]]*=' '{{ config }}' | sed 's/.*=[[:space:]]*//')"
    @echo "server.pglist=$(grep -E '^[[:space:]]*server\.pglist[[:space:]]*=' '{{ config }}' | sed 's/.*=[[:space:]]*//')"
    @echo "minipg.port=$(grep -E '^[[:space:]]*minipg\.port[[:space:]]*=' '{{ config }}' | sed 's/.*=[[:space:]]*//')"
    @echo "CONFIG={{ config }}"
    @echo "RUN_DIR={{ run_dir }}"
    @echo "STATE={{ state }}"
    @echo "LOG_FILE={{ log_file }}"

local-reset:
    @rm -rf "{{ run_dir }}" "{{ local_dir }}/logs" "{{ config }}"
    @just --justfile "{{ justfile_directory() }}/justfile" local-prepare

local-status:
    @echo "watcher.cluster-port=$(grep -E '^[[:space:]]*watcher\.cluster-port[[:space:]]*=' '{{ config }}' | sed 's/.*=[[:space:]]*//' || echo 'MISSING (run just local-prepare)')"
    @echo "server.pglist=$(grep -E '^[[:space:]]*server\.pglist[[:space:]]*=' '{{ config }}' | sed 's/.*=[[:space:]]*//' || echo 'MISSING (run just local-prepare)')"
    @echo "minipg.port=$(grep -E '^[[:space:]]*minipg\.port[[:space:]]*=' '{{ config }}' | sed 's/.*=[[:space:]]*//' || echo 'MISSING (run just local-prepare)')"
    ls "{{ run_dir }}"
    @python3 -c "import json; d=json.load(open('{{ state }}')); print('STATE OK: clusterStatus=%s servers=%d' % (d.get('clusterStatus'), len(d.get('clusterServers', []))))"

local-logs N="100":
    @if [ -f "{{ log_file }}" ]; then tail -n "{{ N }}" "{{ log_file }}"; else echo "No log file yet at {{ log_file }} (run just run-local first)"; fi

run-local:
    @cd "{{ run_dir }}" && jar=$(ls ../../../app/target/bfm-app-*.jar 2>/dev/null | head -n 1 || true) && [ -n "$jar" ] || { echo "ERROR: no jar at app/target/bfm-app-*.jar (hint: just build)" >&2; exit 1; } && exec java -Dspring.config.location="file:{{ config }}" -jar "$jar"

local-verify:
    @test -f "{{ config }}" || (echo "FAIL: CONFIG missing at {{ config }} (run just local-prepare)" >&2; exit 1); echo "OK config exists: {{ config }}"
    @grep -Eq '^[[:space:]]*watcher\.cluster-port[[:space:]]*=[[:space:]]*9995([[:space:]]*$|[[:space:]])' "{{ config }}" || (echo "FAIL: watcher.cluster-port != 9995 in {{ config }}" >&2; exit 1); echo "OK watcher.cluster-port=9995"
    @python3 -c "import json,sys; d=json.load(open('{{ state }}')); assert isinstance(d.get('clusterServers'), list) and d['clusterServers'], 'clusterServers missing/empty'; print('OK state valid JSON with clusterServers: {{ state }}')" || (echo "FAIL: STATE not valid JSON with clusterServers: {{ state }}" >&2; exit 1)
    @git -C "{{ justfile_directory() }}" diff --quiet HEAD -- bfm_status.json || (echo "FAIL: repo-root ./bfm_status.json modified (local runs must not touch it)" >&2; exit 1); echo "OK repo-root bfm_status.json untouched"

# --- BFM fast environment (v1: healthy + unreachable-primary, see tools/fast-env/fast-env.sh) ---
# Primary loop is IDE-owned BFM: fast-prepare -> fast-start-dependencies ->
# F5 "BFM — fast environment" -> fast-validate-dependencies.
# fast-start / fast-validate are helper-owned-BFM wrappers (green in v1).
fast_env_sh := justfile_directory() + "/tools/fast-env/fast-env.sh"

fast-prepare scenario="healthy":
    @bash "{{ fast_env_sh }}" prepare "{{ scenario }}"

fast-start-dependencies:
    @bash "{{ fast_env_sh }}" start-dependencies

fast-validate-dependencies:
    @bash "{{ fast_env_sh }}" validate-dependencies

fast-status:
    @bash "{{ fast_env_sh }}" status

fast-logs n="100":
    @bash "{{ fast_env_sh }}" logs "{{ n }}"

fast-stop:
    @bash "{{ fast_env_sh }}" stop

fast-reset:
    @bash "{{ fast_env_sh }}" reset

fast-start:
    @bash "{{ fast_env_sh }}" start

fast-validate:
    @bash "{{ fast_env_sh }}" validate

# --- BFM live environment (v1: healthy + kill-primary, see tools/live-env/live-env.sh) ---
# Primary loop is IDE-owned BFM: live-prepare -> live-start-dependencies ->
# F5 "BFM — live environment" -> live-validate-dependencies.
# live-start / live-validate are helper-owned-BFM wrappers.
# live-kill-primary / live-rejoin drive the kill-primary scenario phases.
live_env_sh := justfile_directory() + "/tools/live-env/live-env.sh"

live-prepare scenario="healthy":
    @bash "{{ live_env_sh }}" prepare "{{ scenario }}"

live-start-dependencies:
    @bash "{{ live_env_sh }}" start-dependencies

live-validate-dependencies:
    @bash "{{ live_env_sh }}" validate-dependencies

live-status:
    @bash "{{ live_env_sh }}" status

live-logs n="100":
    @bash "{{ live_env_sh }}" logs "{{ n }}"

live-stop:
    @bash "{{ live_env_sh }}" stop

live-reset:
    @bash "{{ live_env_sh }}" reset

live-start:
    @bash "{{ live_env_sh }}" start

live-validate:
    @bash "{{ live_env_sh }}" validate

live-kill-primary:
    @bash "{{ live_env_sh }}" kill-primary

live-rejoin:
    @bash "{{ live_env_sh }}" rejoin
