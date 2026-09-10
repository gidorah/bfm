# `healthy` fixtures (fast environment, milestone 1)

## Layout

- `pgwire-node1.json` — PRIMARY `127.0.10.11:5432` rows for `pgwire-stub.py --fixture`.
- `pgwire-node2.json` — REPLICA `127.0.10.12:5433` rows (empty
  `pg_stat_replication`, `conninfo` with `host=127.0.10.11 port=5432`).
- `minipg-node1/` — WireMock mappings served on `127.0.10.11:7779`.
- `minipg-node2/` — WireMock mappings served on `127.0.10.12:7779`.

## MiniPG conventions

- One file per route (`<op>.json`, exact `url` match, `Basic .+` required) plus
  one shared `unauthorized.json` (`method: ANY`, `urlPattern` over the 16 known
  routes, `Authorization absent` → `401` + `WWW-Authenticate: Basic ...`).
- Unknown routes match nothing → WireMock default `404`. Deferred ops (`stop`,
  `pre-so`, `post-so`, `setappname`) are intentionally unmapped.
- Every 200 body but two identifies its node (`node=127.0.10.1x`), so routing
  is provable per route with plain curl.
- `rewind`/`rebaseUp` answer byte-exact `OK`: BFM compares them with
  `equals("OK")` in its rejoin paths and real MiniPG answers `OK` there too.
- `start` answers `done - server started on node=...`, which is what
  `MinipgAccessUtil.startPg` maps to `OK` (and still names the node).
- No mapping echoes request bodies (`updatepgpass` carries PG creds).
