# Stub MiniPG HTTP plus PG wire protocol, no Docker in the fast environment

BFM derives `DatabaseStatus` from JDBC (`pg_is_in_recovery()`, `pg_stat_replication`, WAL LSN, `timeline_id`), so an HTTP-only stub would force every node `INACCESSIBLE` and cannot show healthy, lag, or timeline decisions.

## Scope

Fast environment

## Decision

Fast environment runs real BFM on the host with WireMock for MiniPG HTTP plus a small per-node PG-wire stub answering the full canned SQL inventory from scenario fixtures (12 fixed shapes in `PostgresqlServer`, mixed `Statement`/`PreparedStatement`, plus arbitrary `executeStatement`). No Docker, no real PostgreSQL.

The PG-wire stub is unproven until exercised with the application's actual JDBC driver (startup/SSL negotiation, column metadata, extended-protocol prepared statements, teardown/reconnect, explicit errors for unknown SQL).

## MiniPG auth

`/pgstatus` sends preemptive Basic auth; Apache-based ops rely on a 401 challenge (no preemptive auth cache). Fixtures return `401 + WWW-Authenticate: Basic` for known protected routes lacking credentials; 404 is reserved for unknown routes.

## Considered Options

- HTTP-only WireMock: cheapest, but leaves the decision inputs uncovered.
- Real disposable PostgreSQL containers: faithful SQL, but pays container + replication setup cost in the fast loop; reserved for the live environment.
