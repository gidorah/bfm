# BFM live environment

Disposable PostgreSQL streaming-replication cluster with the real
`minipg4patroni` jar as the per-node sidecar, where BFM owns failover.
Separate from the fast environment.

Full contract lives in issue #18 (agreed 2026-09-10) as amended by #23;
constraints live in `docs/decisions/0005-live-environment-real-minipg.md`
(real jar, bridge topology — supersedes 0004's agent choice) plus `0001`–`0003`
(stub scope, loopback shape, lifecycle shape). This page is an index, not a
copy.

## Goal

From a fresh checkout: `just live-prepare` stages config + compose stack,
`just live-start-dependencies` boots real PostgreSQL + real MiniPG jar
containers, F5 (`BFM — live environment`) starts BFM in the debugger,
`just live-validate-dependencies` verifies. Fresh-checkout prerequisites
are listed below, not assumed.

## Prerequisites

- Docker Engine + compose plugin (`docker compose version` must work).
- `psql` client (used by `rejoin`/`validate` probes, never by BFM itself).
- BFM jar via `just build` (helper-owned `start` / IDE F5 run it).
- Sibling checkout `../minipgonpatroni` (same parent dir as this repo: if BFM
  is `~/Dev/bfm/bfm`, the MiniPG source is `~/Dev/bfm/minipgonpatroni`,
  Java 21 / Boot 3.3.4) plus the built jar
  `app/target/minipg4patroni-app-1.2.3.jar` via
  `./mvnw -f $MINIPG_ROOT/pom.xml -pl app -am package`.
  Override the jar path with `BFM_LIVE_MINIPG_JAR=` (absolute path to a
  prebuilt jar); otherwise the Docker build uses the sibling-checkout jar.
- Host kernel routes the pinned bridge subnet below (no `ports:` published;
  the host reaches container IPs directly). BFM itself stays on
  `127.0.0.1:9995`.

## Topology

| Piece | Address (exact) |
|---|---|
| Bridge subnet (one fixed bridge, static member IPs) | `172.30.51.0/24` |
| BFM (`watcher.cluster-port` + generated `server.address=127.0.0.1`) | `127.0.0.1:9995` |
| BFM4Patroni (reserved by the dev port split — this env must never bind it) | `127.0.0.1:9994` |
| PG node 1 (primary, `live-pg1` / `bfm-live-pg1`) | `172.30.51.11:5432` |
| PG node 2 (replica, `live-pg2` / `bfm-live-pg2`) | `172.30.51.12:5432` |
| MiniPG per node (real `minipg4patroni` jar, same port per IP) | `172.30.51.11:7779`, `172.30.51.12:7779` |
| VIP (spare bridge IP, moved by the jar via `ip`) | `172.30.51.100` |
| Peer BFM | `no-pair` (second BFM only for `pair-takeover`, deferred) |

Compose project is `bfm-live`; services are `live-pg1`/`live-pg2`
(containers `bfm-live-pg1`/`bfm-live-pg2`), each bundling one PostgreSQL
plus its real MiniPG jar sidecar on its own static bridge IP.
`server.pglist=172.30.51.11:5432,172.30.51.12:5432`, `minipg.port=7779`
(distinct IPs, same port — same shape as ADR-0002, new subnet), fixed
test-only credentials bfm/bfm (bridge-only disposable env, same convention
as the fast env). All PG instances run `wal_log_hints=on` (#14 prerequisite:
without it `pg_rewind`-based rejoin cannot work; the jar's `bfm` mode also
enforces `wal_log_hints`/`hot_standby` itself at startup — keep both, they
agree). No `ports:` are published on either member service; the host reaches
container IPs directly because the host kernel routes the bridge.
`live-env.sh` loopback-only guards carry a documented carve-out for this
pinned disposable subnet, fail-closed everywhere else. Port checks test
addr/port tuples (and wildcard conflicts), never bare ports.

Bare-local, fast, and live runs all bind `127.0.0.1:9995` and must never
overlap. Existing `BFM — local cluster` and `BFM — fast environment` F5
configs plus `local-*`/`fast-*` paths are untouched; the new
`BFM — live environment` F5 config points at `_work-tmp/live-env/`
(config + CWD). Disposable-state inventory under `_work-tmp/live-env/`:
generated `application.properties`, staged `compose.yaml`, staged
`minipg.jar` (prepare copies the chosen jar here, honoring
`BFM_LIVE_MINIPG_JAR=`; the single static
`tools/live-env/configuration.json` needs no staging — the image COPYs it
baked), `run/` (`bfm_status.json`, BFM CWD — only disposable state), `logs/`, `.launch-id` / `.owner` / `.scenario`. Named volumes owned
by project `bfm-live` hold PG data dirs and are removed by `reset`.
Repo-root `bfm_status.json` is never touched.

## Jar build

One container per member: image = stock `postgres:14.13-bookworm` + Temurin
JRE 21 copied in + `COPY minipg.jar` + `iproute2` + passwordless sudo for the
exact VIP/`postVipUp` commands. PG14 is pinned: the jar's `PgVersion` enum
maxes out at `V14X` (`valueOf("V16X")` throws) and jar+PG14 is the proven
combo; BFM's SQL needs nothing newer. Build the jar from the sibling checkout
(see Prerequisites); the Docker build copies it in. Never PG16.

## Per-node `configuration.json`

Baked into the image at the jar CWD (`/opt/bfm/configuration.json`,
CWD-relative `./configuration.json`) — the jar reads it from its working
directory. Single static file, no per-node templating (every value is
node-identical: shared VIP, identical PG paths, fixed test-only bfm/bfm
creds, same port). Mandatory values: `"clusterManager": "bfm"`
(NOT omittable: `MiniPGHelper.java:77` calls
`getClusterManager().equals("bfm")` → null NPEs; the `"bfm"` branch is what
enables PG auto-manage), `pgVersion: V14X`,
`postgresBinPath`/`pgCtlBinPath: "/usr/lib/postgresql/14/bin/"` (trailing
slash is load-bearing — the jar concatenates `pgCtlBinPath + "pg_ctl"`),
`postgresDataPath` to the node's data dir, fixed test-only creds bfm/bfm,
`port: 7779`, `vipInterface: eth0` (verify at runtime, do not assume),
`postVipUp: /bin/true`. Omit Patroni-only keys (`patroniCtlBinPath`,
`patroniConfFilePath`). The jar must run with postgres ownership of PG paths;
`psql` on PATH with sane local-probe defaults.

## BFM owns failover

BFM performs failover itself via direct JDBC, MiniPG sidecar ops, and an
optional paired BFM. The existing Patroni stack is infrastructure reference
only — it is never the cluster under test, and no Patroni-managed cluster,
etcd, or HAProxy may appear in this environment. Results must reflect BFM's
behavior. No BFM app (`app/`) changes.

## Lifecycle

`tools/live-env/live-env.sh` plus `just live-*` wrappers; `local-*` and
`fast-*` untouched:

```text
prepare [healthy|kill-primary] → start-dependencies → validate[-dependencies] → status/logs → stop → reset
```

plus `kill-primary` / `rejoin` scenario actions and helper-owned
`start` / `validate` wrappers.

- Primary debug loop: `prepare healthy → start-dependencies → F5 (live
  config) → validate-dependencies`.
- Secondary green-check: helper-owned `start → validate`.
- Lifecycle split (despite the issue's "`just live-prepare` brings up a fresh
  stack" phrasing): `prepare` is docker-independent and only renders config +
  staged compose + staged `minipg.jar` + staged seed, while
  `start-dependencies` builds/starts the 2-node stack.
- A scenario is one immutable seed selected at `prepare` time; changing it on
  a running stack requires `stop`/`reset` + `prepare` (idle re-`prepare`
  simply re-seeds: fresh launch-id, staged fixtures, empty state).

## Scenarios

- `healthy`: primary/replica roles visible, replication flowing; `validate`
  greens with real MASTER/SLAVE observations.
- `kill-primary` (demo arc): `kill-primary` stops/kills the primary PG;
  BFM promotes the latest replica via the real jar and the VIP moves via the
  jar's real `ip` ops; `rejoin` rejoins the old primary as replica
  (`pg_rewind` + `pg_basebackup` path). `validate` is phase-aware: pre-kill
  it asserts `healthy` state, post-kill it asserts the promoted MASTER plus
  rejoin convergence, never a stale pre-kill `HEALTHY`.

Deferred (fail closed at `prepare`; each names its home issue):
`replica-data-loss` (#9), `lag-threshold` (#13), `switchover-tablespaces`
(#11), `pair-takeover` (#12, needs a second BFM process). Failover
reproductions for #6–#8 and #10 land here as their scenarios open.

## VIP without VMs

No VM-based layer (per source doc): VIP movement is performed by the real jar
(`sudo ip address add/del <vipIp>/<netmask> dev <vipInterface>` inside the
container netns, then `sudo <postVipUp>`, `MiniPGController.java:201-275`).
Image and compose provide `iproute2` + passwordless sudo for those exact
commands, `cap_add: [NET_ADMIN]` on both member services, the spare VIP IP,
and `postVipUp: /bin/true`.

VIP proof is read-only `docker exec` inspection, never `checkvip`:
`checkvip` lists interfaces and, when the VIP is absent, attempts `vipUp()`
itself (`VIP-SET:OK`) — calling it manufactures the very state it inspects.
Prove VIP instead by (a) `ip address show` via `docker exec` on both nodes
(exactly one holder), (b) holder == current SQL MASTER
(`pg_is_in_recovery()=f`), (c) a replicated write on the master visible per
`pg_stat_replication`.

## Validate and safety (summary)

Validate is the readiness gate asserting live PG reachability, replication
state, real-jar MiniPG health (`/minipg/pgstatus` off the running jar),
fresh BFM observations, and expected `bfm_status.json` state for the prepared
scenario: bounded polling (no sleeps), per-tuple liveness, real
`pg_is_in_recovery()` roles with retry-on-truncated-write state handling,
real active/no-pair discovery, IDE-case config/CWD identity check (a listener
on 9995 alone is insufficient), bridge-subnet carve-out with loopback-only
fail-closed behaviour elsewhere, redaction, and disposable-state invariants.
See `live-env.sh` for the full per-phase contract.

## Troubleshooting

- Port clashes: `status` shows per-tuple LISTENING/free with owning PIDs;
  stop the overlapping bare-local / fast / live run (all share
  `127.0.0.1:9995`) before `prepare`. The bridge IPs need no published
  ports; if `172.30.51.x` is unreachable, the host is not routing the
  bridge network (check `docker network inspect bfm-live`).
- Trailing slash: if the jar logs concatenation failures around `pg_ctl`,
  the staged `configuration.json` lost its trailing slashes on
  `postgresBinPath`/`pgCtlBinPath` — re-`prepare` from the template.
- `clusterManager` NPE at jar startup means the staged `configuration.json`
  omitted `"clusterManager": "bfm"` — re-`prepare` from the template.
- Jar 404/401 on `/minipg/*`: the jar is running but the route/creds drifted
  from BFM's `MinipgAccessUtil` table — compare against the running jar,
  never against remembered agent behaviour.
- Stale volumes: a previous run's PG data survives in project `bfm-live`
  named volumes; `reset` removes them — rerun `reset` + `prepare` for a
  clean cluster. Never delete another project's volumes.
- Repo-root guard: `test-helper.sh` checksums repo-root `bfm_status.json`
  plus `_work-tmp/local/` and `_work-tmp/fast-env/` before/after; any
  modification fails the self-test. Live state lives only under
  `_work-tmp/live-env/`.
- No docker daemon: `prepare`, `status`, `logs`, `stop`, and the
  fail-closed `validate`/`kill-primary`/`rejoin` refusals need no daemon;
  daemon-dependent checks report SKIP, not failure.
- Sibling checkout absent: jar-dependent image builds fail clearly; set
  `BFM_LIVE_MINIPG_JAR=` to a prebuilt jar or clone the sibling checkout
  (see Prerequisites).
