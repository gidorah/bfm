# Give each fast-env PG node its own loopback IP

`MinipgAccessUtil` builds the MiniPG URL from the PG host plus one global `minipg.port`, so `127.0.0.1:5432,127.0.0.1:5433` collapses both nodes onto one MiniPG identity.

## Scope

Fast environment

## Decision

Fast-env `server.pglist` uses distinct loopback IPs (e.g. `127.0.10.11:5432,127.0.10.12:5433`) with per-IP MiniPG (both `:7779`) and per-IP PG-wire stubs. The single `minipg.port` assumption is preserved because routing differs by IP.
