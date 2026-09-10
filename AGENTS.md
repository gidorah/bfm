# AGENTS.md

## Build / test (Maven 3.9.12, Java 21, Spring Boot 3.3.4)

- Toolchain: `mise.toml` pins Java `temurin-21.0.11+10.0.LTS`; the Maven wrapper (`./mvnw`, 3.9.12) works — use it, not system `mvn`.
- Multi-module root (`packaging: pom`): `app` (executable jar), `rpm`, `deb` (packaging only).
- Daily loop (app only, no rpm/deb tooling needed): `just test` (= `./mvnw -f app/pom.xml test`), `just build` (= `./mvnw -f app/pom.xml clean package`).
- Full build incl. packages: `just package-all` (= `./mvnw clean package`; add `-DskipTests` to skip tests). rpm/deb `jdeb`/`rpm-maven-plugin` consume `app/target/bfm-app-*.jar`. No lint/format/typecheck config exists.
- Tests: only placeholder `app/src/test/java/com/bisoft/bfm/BfmApplicationTests.java` (plain JUnit, no Spring context).
- Only CI is CodeQL autobuild on `main` (`.github/workflows/codeql-analysis.yml`); no build/test gate to mirror.

## Structure / entrypoints

- `app/src/main/java/com/bisoft/bfm/BfmApplication.java` — entrypoint; sets default props in code (logging to `log/app.log`, `management.endpoints.web.exposure.include=restart`).
- `BfmController.java` (`/bfm/*`) — all REST + server-rendered HTML (`index.html`, `template.html` in `app/src/main/resources/`, `{{ PLACEHOLDERS }}` replaced in code). Single fat controller (~900 lines); put new endpoints there.
- `scheduler/ClusterCheckScheduler.java` — failover brain, 3 `@Scheduled` loops: `checkCluster` 5s, `checkUnavailable` 7s, `amIMasterBfm` 11s.
- `model/BfmContext.java` (`@Component`) — mutable singleton holding `pgList`, `masterServer`, `clusterStatus`, pause flags. `model/PostgresqlServer.java` + `helper/SqlExecutor.java` do direct JDBC per node.
- `helper/MinipgAccessUtil.java` — talks to per-node `minipg` sidecar agent (promote/rewind/rebase/VIP ops). `helper/BfmAccessUtil.java` — pair-BFM communication. `helper/SymmetricEncryptionUtil.java` — AES-GCM password crypto.
- `bfmctl` (repo root) — bash CLI wrapping the REST API; run as `bash bfmctl` (no exec bit). Source of truth for endpoint paths.

## Runtime / config gotchas

- No `application.properties` under `app/src/main/resources/`. Runtime config lives in `rpm|deb/src/main/resources/settings/application.properties` and is installed to `/etc/bfm/bfmwatcher/application.properties`. For local runs, copy one of those next to the working dir or pass `-Dspring-boot.run.arguments=--spring.config.location=...`.
- `server.pglist` format: `host:port[,host:port]` with optional `|priority` suffix (`h:5432|2`), parsed in `BfmContext.init()`.
- Active/passive BFM state is a CWD-relative file: `./bfm_status.json` (written by active, read by passive; also committed at repo root as a sample — don't treat as live state). Logs go to CWD-relative `log/app.log` per `BfmApplication` defaults.
- `spring.profiles.active=@spring.profiles.active@` in `BfmApplication` is a literal (no resource filtering configured) — ignore it.
- Auth: `WebSecurityConfig` requires auth on **every** request (CSRF off, form-login → `/bfm/index.html` + httpBasic). Creds are `server.pguser`/`server.pgpassword`. `bfmctl` requires `-u <user>` + interactive password; `-p` is explicitly rejected.
- Encrypted secrets: when `bfm.user-crypted=true`, passwords/TLS secret are AES-GCM via `SymmetricEncryptionUtil` (key `bfm.approval-key`, default `B1s0ft25`). Generate values via live endpoint `POST /bfm/encrypt/{clear}` (i.e. `bfmctl -encrypt <clear>`), never hand-roll.
- Watch strategies accepted by `POST /bfm/watch-strategy/{A|M}` are only `A` (availability) / `M` (manual); other values fail. Destructive ops (`switchover`, `reinit`) only run on the active BFM and pause checks internally.
- Packaging: systemd unit + `bfm.sh` + `bfmctl` ship from `rpm|deb/src/main/resources/` to `/etc/bfm/bfmwatcher`, service user `postgres`. TLS artifacts at repo root (`bfm.p12`, `bfm.jks`, `cert.pem`, `key.pem`) are sample/dev secrets.

### Local run (dev-only, no prod changes)

- `just local-prepare` generates `CONFIG=_work-tmp/local/application.properties` + `RUN_DIR=_work-tmp/local/run/` from `dev/local/` templates; see `dev/local/README.md`.
- `just run-local` starts the built jar with `CWD=RUN_DIR` plus `-Dspring.config.location=file:<abs CONFIG>`; `just build` first to refresh the jar.
- `just local-status` shows ports/pglist from CONFIG + validates `STATE=_work-tmp/local/run/bfm_status.json`; `just local-logs` tails `LOG_FILE=_work-tmp/local/logs/app.log`.
- `just local-reset` deletes generated `_work-tmp/local/` (safe: regenerable via local-prepare); `just local-verify` checks (a) CONFIG exists, (b) watcher.cluster-port=9995, (c) STATE valid JSON with clusterServers, (d) repo-root bfm_status.json untouched — it does NOT check CWD wiring, live ports, or processes.
- VS Code F5 config is `BFM — local cluster` (`.vscode/launch.json`): same CWD + `spring.config.location`; run `just local-prepare` (and `just build`) before F5, no preLaunchTask wired.
- `logging.file.name=../logs/app.log` (resolved from RUN_DIR); `server.pglist=127.0.0.1:5432,127.0.0.1:5433`, `watcher.cluster-pair=no-pair` — no live DB required.
- Port split (dev-only): BFM `watcher.cluster-port=9995` vs BFM4Patroni `9994` vs `minipg.port=7779`, so a local run never clashes with system services.
- Generated `_work-tmp/local/**` is git-ignored — never commit it; repo-root `./bfm_status.json` is a sample and local runs must never modify it.

## Workflow

- Open PRs against `dev` unless explicitly told otherwise. (Both `dev` and `main` exist on origin; past release PRs targeted `main`.)

## Agent skills

### Issue tracker

Issues live in GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (root `CONTEXT.md` + `docs/decisions/`). See `docs/agents/domain.md`.
