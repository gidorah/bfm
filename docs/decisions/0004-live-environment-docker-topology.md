# Run the live environment as one Docker service per PG+MiniPG node on distinct loopbacks

## Scope

Live environment

## Decision

The live stack is one compose project (`bfm-live`) with two services
(`live-pg1`/`live-pg2`, containers `bfm-live-pg1`/`bfm-live-pg2`), each
bundling one PostgreSQL plus its MiniPG agent on its own loopback
(`127.0.10.11:5432`, `127.0.10.12:5433`).

Nodes share one `minipg.port` (`7779`) per IP, reusing the ADR-0002 shape:
routing differs by IP, so the single-port assumption is preserved.

Each MiniPG is a compatible Python agent performing real
`pg_ctl`/`pg_rewind`/`pg_basebackup` ops against its local PG — not the
patroni-coupled `minipg4patroni` jar, which answers to Patroni instead of
BFM and would test the wrong owner.

All PG instances run `wal_log_hints=on` (#14; `pg_rewind` cannot work
without it). BFM itself runs on the host at `127.0.0.1:9995` against
`server.pglist=127.0.10.11:5432,127.0.10.12:5433` with
`watcher.cluster-pair=no-pair` (second BFM only for deferred
`pair-takeover`). `kill-primary` validate is phase-aware (pre-kill `healthy`
state, post-kill promoted MASTER + rejoin convergence). PG data lives in
named volumes owned by project `bfm-live`; `reset` removes them.

## Considered Options

- `minipg4patroni` jar per node: cheapest, but patroni-coupled — rejected.
- Host-run PG binaries: no container isolation, host-version drift.
- Patroni-managed cluster under test with BFM observing: richest infra,
  but BFM must own failover — rejected (Patroni stack stays reference only).

Refs: #18, #14, ADRs 0001–0003.
