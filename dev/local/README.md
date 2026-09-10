# Local run (dev-only)

Isolated dev loop. No production code or packaging is touched. No live dependencies required (no real Postgres needed for startup checks; `server.pglist` points at loopback placeholders).

## Fresh-checkout flow

```bash
just local-prepare   # generate _work-tmp/local/{application.properties,run/}
just build           # build app jar (./mvnw -f app/pom.xml clean package)
# then either:
#   F5 "BFM — local cluster" in VS Code
# or:
just run-local       # java -jar app/target/bfm-app-*.jar, CWD=_work-tmp/local/run
just local-status    # show ports/pglist from CONFIG + validate STATE
just local-logs      # tail generated LOG_FILE
just local-reset     # delete generated _work-tmp/local (safe: regenerable via local-prepare)
```

`just local-verify` checks (a) CONFIG exists, (b) watcher.cluster-port=9995, (c) STATE valid JSON with clusterServers, (d) repo-root bfm_status.json untouched.

## Paths

| Name | Path | Source |
| --- | --- | --- |
| Template | `dev/local/application.properties` | committed, edit here |
| Template seed | `dev/local/bfm_status.json.seed` | committed, copied on prepare |
| CONFIG (generated) | `_work-tmp/local/application.properties` | from template via `just local-prepare` |
| RUN_DIR (generated) | `_work-tmp/local/run` | created by `just local-prepare`, process CWD |
| STATE (generated) | `_work-tmp/local/run/bfm_status.json` | written at runtime, seeded from `bfm_status.json.seed` |
| LOG_FILE (generated) | `_work-tmp/local/logs/app.log` | via `logging.file.name=../logs/app.log` from RUN_DIR |

All `_work-tmp/` paths are generated and git-ignored. Never commit them.

## Port split

| Listener | Port | Property | Why |
| --- | --- | --- | --- |
| BFM watcher | 9995 | `watcher.cluster-port` | avoids clashing with a system BFM on the default port |
| BFM4Patroni listener (separate repo) | 9994 | — | keep off the BFM watcher port |
| minipg | 7779 | `minipg.port` | keeps the per-node agent API off both BFM ports |

Fixed local values: `server.pglist=127.0.0.1:5432,127.0.0.1:5433`, `watcher.cluster-pair=no-pair`.

## State-file rule

Repo-root `./bfm_status.json` is a committed sample. Local runs must never read or modify it: CLI and F5 launches use `CWD=_work-tmp/local/run` with `-Dspring.config.location=file:<abs _work-tmp/local/application.properties>`, so all state goes to generated `STATE`.

## spring-boot:run alternative

Documented but not the default: `cd _work-tmp/local/run` then `./mvnw -f <abs app/pom> spring-boot:run` with `spring-boot.run.arguments=--spring.config.location=file:<abs CONFIG>`. `just run-local` uses the built jar instead.
