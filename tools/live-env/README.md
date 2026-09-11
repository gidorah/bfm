# BFM live environment

Disposable PostgreSQL streaming-replication cluster with real MiniPG agents
where BFM owns failover. Separate from the fast environment.

Full contract lives in issue #18 (agreed 2026-09-10); constraints live in
`docs/decisions/0004-live-environment-docker-topology.md` (topology) plus
`0001`–`0003` (stub scope, loopback shape, lifecycle shape). This page is an
index, not a copy.

## Goal

From a fresh checkout: `just live-prepare` stages config + compose stack,
`just live-start-dependencies` boots real PostgreSQL + MiniPG containers,
F5 (`BFM — live environment`) starts BFM in the debugger,
`just live-validate-dependencies` verifies. Fresh-checkout prerequisites
are listed below, not assumed.

## Prerequisites

- Docker Engine + compose plugin (`docker compose version` must work).
- `psql` client (used by `rejoin`/`validate` probes, never by BFM itself).
- BFM jar via `just build` (helper-owned `start` / IDE F5 run it).
- Ports free as exact tuples (see table): `127.0.0.1:9995`,
  `127.0.10.11:5432`, `127.0.10.12:5433`, `127.0.10.11:7779`,
  `127.0.10.12:7779`.

## Topology

| Piece | Address (exact bind tuple) |
|---|---|
| BFM (`watcher.cluster-port` + generated `server.address=127.0.0.1`) | `127.0.0.1:9995` |
| BFM4Patroni (reserved by the dev port split — this env must never bind it) | `127.0.0.1:9994` |
| PG node 1 (primary, `live-pg1` / `bfm-live-pg1`) | `127.0.10.11:5432` |
| PG node 2 (replica, `live-pg2` / `bfm-live-pg2`) | `127.0.10.12:5433` |
| MiniPG agent per node (compatible Python agent, same port per IP) | `127.0.10.11:7779`, `127.0.10.12:7779` |
| Peer BFM | `no-pair` (second BFM only for `pair-takeover`, deferred) |

Compose project is `bfm-live`; services are `live-pg1`/`live-pg2`
(containers `bfm-live-pg1`/`bfm-live-pg2`), each bundling one PostgreSQL
plus its MiniPG agent. `server.pglist=127.0.10.11:5432,127.0.10.12:5433`,
`minipg.port=7779`, fixed test-only credentials bfm/bfm (loopback-only,
same convention as the fast env). All PG instances run `wal_log_hints=on`
(#14 prerequisite: without it `pg_rewind`-based rejoin cannot work).
Port checks test addr/port tuples (and wildcard conflicts), never bare ports.

Bare-local, fast, and live runs all bind `127.0.0.1:9995` and must never
overlap. Existing `BFM — local cluster` and `BFM — fast environment` F5
configs plus `local-*`/`fast-*` paths are untouched; the new
`BFM — live environment` F5 config points at `_work-tmp/live-env/`
(config + CWD). Disposable-state inventory under `_work-tmp/live-env/`:
generated `application.properties`, staged `compose.yaml`, `run/`
(`bfm_status.json`, BFM CWD — only disposable state), `logs/`,
`.launch-id` / `.owner` / `.scenario`. Named volumes owned by project
`bfm-live` hold PG data dirs and are removed by `reset`. Repo-root
`bfm_status.json` is never touched.

## BFM owns failover

BFM performs failover itself via direct JDBC, MiniPG sidecar ops, and an
optional paired BFM. The existing Patroni stack is infrastructure reference
only — it is never the cluster under test, and no Patroni-managed cluster
may appear in this environment. Results must reflect BFM's behavior.

## Lifecycle

`tools/live-env/live-env.sh` plus `just live-*` wrappers; `local-*` and
`fast-*` untouched:

```text
prepare [healthy|kill-primary] → start-dependencies → validate[-dependencies] → status/logs → stop → reset
```

plus `kill-primary` / `rejoin` scenario actions.

- Primary debug loop: `prepare healthy → start-dependencies → F5 (live
  config) → validate-dependencies`.
- Secondary green-check: helper-owned `start → validate`.
- Lifecycle split (despite the issue's "`just live-prepare` brings up a fresh
  stack" phrasing): `prepare` is docker-independent and only renders config +
  staged compose + staged seed, while `start-dependencies` builds/starts the
  2-node stack.
- A scenario is one immutable seed selected at `prepare` time; changing it on
  a running stack requires `stop`/`reset` + `prepare` (idle re-`prepare`
  simply re-seeds: fresh launch-id, staged fixtures, empty state).

## Scenarios

- `healthy`: primary/replica roles visible, replication flowing; `validate`
  greens with real MASTER/SLAVE observations.
- `kill-primary` (demo arc): `kill-primary` stops/kills the primary PG;
  BFM promotes the latest replica and the VIP marker moves; `rejoin`
  rejoins the old primary as replica (`pg_rewind` + `pg_basebackup`
  path). `validate` is phase-aware: pre-kill it asserts `healthy` state,
  post-kill it asserts the promoted MASTER plus rejoin convergence, never
  a stale pre-kill `HEALTHY`.

Deferred (fail closed at `prepare`; each names its home issue): 
`replica-data-loss` (#9), `lag-threshold` (#13), `switchover-tablespaces`
(#11), `pair-takeover` (#12, needs a second BFM process). Failover
reproductions for #6–#8 and #10 land here as their scenarios open.

## VIP without VMs

No VM-based layer yet (per source doc): VIP movement is proven by marker
semantics only — the MiniPG agent records which node currently holds the
VIP marker, and `validate` asserts the marker moved with promotion. Real
VIP / service-management behavior gets a VM layer when that work becomes
relevant.

## Validate and safety (summary)

Validate is the readiness gate asserting live PG reachability, replication
state, MiniPG agent health, fresh BFM observations, and expected
`bfm_status.json` state for the prepared scenario: bounded polling (no
sleeps), per-tuple liveness, real `pg_is_in_recovery()` roles with
retry-on-truncated-write state handling, real active/no-pair discovery,
IDE-case config/CWD identity check (a listener on 9995 alone is
insufficient), loopback-only fail-closed behaviour, redaction, and
disposable-state invariants. See `live-env.sh` for the full per-phase
contract.

## Troubleshooting

- Port clashes: `status` shows per-tuple LISTENING/free with owning PIDs;
  stop the overlapping bare-local / fast / live run (all share
  `127.0.0.1:9995`) before `prepare`.
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
