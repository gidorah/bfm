# AGENTS.md

## Build / test (Maven, Java 21, Spring Boot 3.3.4)

- Maven wrapper is broken (`.mvn/wrapper/` was never committed — `sh mvnw` fails). Use system `mvn` (3.9.x) with Java 21.
- Multi-module root (`packaging: pom`): `app` (executable jar), `rpm`, `deb` (packaging only).
- Build app: `mvn -pl app -am package -DskipTests`
- Full build incl. packages: `mvn package -DskipTests` (rpm/deb `jdeb`/`rpm-maven-plugin` consume `app/target/bfm-app-*.jar`, so build `app` first; no lint/format/typecheck config exists).
- Tests: only placeholder `app/src/test/java/com/bisoft/bfm/BfmApplicationTests.java` (plain JUnit, no Spring context). Run: `mvn -pl app test -Dtest=BfmApplicationTests`
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

## Workflow

- Open PRs against `dev` unless explicitly told otherwise. (Both `dev` and `main` exist on origin; past release PRs targeted `main`.)

## Agent skills

### Issue tracker

Issues live in GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (root `CONTEXT.md` + `docs/decisions/`). See `docs/agents/domain.md`.
