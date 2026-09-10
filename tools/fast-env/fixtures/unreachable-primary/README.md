# unreachable-primary (fast-env scenario)

Observation/attempt semantics — NOT a completed failover.

## Topology

- Primary PG-wire listener is ABSENT: no `pgwire-stub.py` process is started
  on `127.0.10.11:5432`. Any JDBC connect to that tuple fails, so
  `PostgresqlServer.getDatabaseStatus()` reports `INACCESSIBLE`
  (all JDBC-failure paths in `PostgresqlServer.java` fall through to
  `DatabaseStatus.INACCESSIBLE`).
- Replica PG-wire is present on `127.0.10.12:5433`
  (`pgwire-node2.json`, `role=replica`): `pg_is_in_recovery()=t`,
  `pg_stat_replication` 0 rows, one `pg_stat_wal_receiver` row with
  `conninfo host=127.0.10.11 port=5432`. Same WAL LSN/timeline as the
  healthy replica.
- BOTH MiniPG WireMock mappings stay up (`minipg-node1/` on
  `127.0.10.11:7779`, `minipg-node2/` on `127.0.10.12:7779`), copied
  verbatim from the healthy fixtures — so `startPg`/`promote`/`rewind`
  attempts against the dead primary's sidecar remain observable via the
  node-specific response bodies (`node=127.0.10.11` vs
  `node=127.0.10.12`, which is what proves request routing).

## Why there is no pgwire-node1.json

Its absence is the point: the harness must not start any PG-wire stub on
`127.0.10.11:5432`. A canned fixture file here would invite exactly that
mistake. Do not add one.

## Canned answers do not change

- Canned `promote → OK` on either MiniPG mapping cannot flip the canned
  `pg_is_in_recovery()=t` served by the replica stub: the two stubs are
  static files with no channel between them.
- `failover()` unconditionally ends `HEALTHY`
  (`app/src/main/java/com/bisoft/bfm/scheduler/ClusterCheckScheduler.java:899-900`
  — `log.error("Failover Finished")` followed by
  `setClusterStatus(ClusterStatus.HEALTHY)` outside the try/catch), so a
  `HEALTHY` cluster status in BFM logs is NOT evidence that the replica
  was promoted or that recovery flipped to `f`. Judge this scenario by
  MiniPG operation counters and PG-wire answers, not by cluster status.

## Layout

```text
unreachable-primary/
├── README.md            # this file
├── pgwire-node2.json    # replica fixture (verbatim copy of healthy)
├── minipg-node1/        # 17 WireMock mappings, verbatim copy of healthy
└── minipg-node2/        # 17 WireMock mappings, verbatim copy of healthy
```
