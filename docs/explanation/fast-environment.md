# BFM fast environment

Disposable host-run BFM with deterministic substitutes. No Docker, no live databases.

Full contract lives in `_work-tmp/fast-environment-plan.md` (agreed 2026-09-10);
constraints live in `docs/decisions/0001-fast-env-stub-scope.md`,
`docs/decisions/0002-fast-env-loopback-topology.md`, and
`docs/decisions/0003-fast-env-lifecycle.md`. This page is an index, not a copy.

## Goal

From a fresh checkout: `just fast-prepare` prepares stub dependencies,
F5 (`BFM — fast environment`) starts BFM in the debugger,
`just fast-validate-dependencies` verifies. Fresh-checkout prerequisites
(pinned toolchain + Bash/curl + Python for the PG-wire stub + pinned/verified
WireMock artifact) are specified in the helper, not assumed.

## Topology (v1)

| Piece | Address (exact bind tuple) |
|---|---|
| BFM (`watcher.cluster-port` + generated `server.address=127.0.0.1`) | `127.0.0.1:9995` |
| PG node 1 (PG-wire stub) | `127.0.10.11:5432` |
| PG node 2 (PG-wire stub) | `127.0.10.12:5433` |
| MiniPG WireMock per node (explicit per-IP bind, same port) | `127.0.10.11:7779`, `127.0.10.12:7779` |
| Peer BFM | `no-pair` (stub deferred; `BfmAccessUtil` short-circuits) |

`server.pglist=127.0.10.11:5432,127.0.10.12:5433`, `minipg.port=7779`,
`minipg.use-tls=false`, `bfm.use-tls=false`, fixed test-only credentials bfm/bfm
(loopback-only, same convention as bfm4patroni's fast env). BFM has global MiniPG creds, so routing is proven with distinct
node-specific responses/events, not cross-credential isolation. Port checks
test addr/port tuples (and wildcard conflicts), never bare ports.

Bare-local and fast runs both bind `127.0.0.1:9995` and must never overlap.
Existing `BFM — local cluster` F5 plus `local-*` paths are untouched; the new
`BFM — fast environment` F5 config points at `_work-tmp/fast-env/`
(config + CWD). Layout under `_work-tmp/fast-env/`: generated
`application.properties`, `run/bfm_status.json` (CWD `run`, only disposable
state), `logs/`, `fixtures/<scenario>/`. Repo-root `bfm_status.json` is never
touched.

## Lifecycle

`tools/fast-env/fast-env.sh` plus `just fast-*` wrappers; `local-*` untouched:

```text
prepare [scenario] → start[-dependencies] → validate[-dependencies] → status/logs → stop → reset
```

- Primary debug loop: `prepare healthy → start-dependencies → F5 (fast config) → validate-dependencies`.
- Secondary green-check: helper-owned `start → validate`.
- A scenario is one immutable fixture set selected at `prepare` time; changing
  it requires `reset` + `prepare`.

## Scenarios (v1 only)

- `healthy`: full canned SQL inventory plus the MiniPG read/write floor; all
  background tasks (5s/6s/7s/9s/11s/30s) observable green.
- `unreachable-primary` (observation/attempt, NOT completed failover): the
  primary PG-wire listener is absent (JDBC → `INACCESSIBLE`) while its MiniPG
  stays up, so `startPg`/`promote`/`rewind` attempts are observable via
  sanitized operation counters. A canned `promote` OK cannot flip canned
  `pg_is_in_recovery()=t`, and `failover()` unconditionally ends `HEALTHY`
  (`ClusterCheckScheduler.java:899-900`), so `HEALTHY` in logs is not success
  evidence. Status writes are gated on `masterServer != null` (`:576-577`),
  so freshness exceptions are specified per scenario.

Deferred to v2: `excessive-lag`, `malformed-minipg`, `unavailable-peer`,
split-brain, stale status file.

## Validate and safety (summary)

Validate is the readiness gate asserting stubs, fresh BFM observations, and
expected `bfm_status.json` state for the prepared scenario: bounded polling
(no sleeps), stubs alive plus expected fixture bytes, fresh discovery logs
covering all healthy background tasks, expected `ClusterStatus`/roles with
retry-on-truncated-write handling, no cross-node mixing, wait for real
active/no-pair discovery (`pairStatus` starts `"Active"`), IDE-case
config/CWD identity check (a listener on 9995 alone is insufficient),
loopback-only fail-closed behaviour, redaction, and disposable-state
invariants.

Safety (bfm4patroni parity, BFM-concrete): explicit `127.0.0.1` bind,
tuple-aware occupancy, proxy bypass, fast-only logging config with
pre-storage redaction (including the IDE case), canonical/symlink/PID
ownership, deployment-path refusal naming BFM install paths, and
artifact pin/checksum for WireMock plus PG-stub prerequisites. See the plan
for the full validate contract, safety list, SQL inventory, and MiniPG
fixture floor.
