# Run the live environment with the real minipg4patroni jar as the per-node sidecar

## Scope

Live environment

## Supersedes

Supersedes `docs/decisions/0004-live-environment-docker-topology.md` on the
MiniPG agent choice only. ADR-0004's lifecycle shape (compose project
`bfm-live`, services `live-pg1`/`live-pg2`, BFM owns failover, `reset`
semantics) stands; its agent choice (compatible Python agent
`tools/live-env/minipg-agent.py`) is withdrawn. The Python agent is deleted
entirely (chop, do not fix/keep).

## Decision

Each live node runs the REAL `minipg4patroni` jar (`minipg4patroni-app-1.2.3.jar`,
built from the sibling checkout `../minipgonpatroni`, override
`BFM_LIVE_MINIPG_JAR=`) as a same-container sidecar next to stock PostgreSQL.
Image = `postgres:14.13-bookworm` + Temurin JRE 21 copied in + `COPY minipg.jar`
+ `iproute2` + passwordless sudo for the exact VIP/`postVipUp` commands.
Single static `tools/live-env/configuration.json` is baked into the image at
the jar CWD (`/opt/bfm/configuration.json`, CWD-relative
`./configuration.json` — the jar reads it from its working directory) with
`"clusterManager": "bfm"`. No per-node templating: every value is
node-identical (shared VIP, identical PG paths, fixed test-only creds, same
port), so one baked file serves both services. The entrypoint starts the DB, waits for health,
then `java -jar minipg.jar &` with `wait -n` + TERM forwarding (reference:
`bfm4patroni-vaadin` `tools/full-local-test/member-entrypoint.sh`). No Patroni
in BFM: the existing primary/replica streaming-replication bootstrap semantics
(incl. `wal_log_hints=on`) are kept; the jar's `bfm` mode also enforces
`wal_log_hints`/`hot_standby` itself at startup (`MiniPGHelper.init`) — keep
both, they agree.

Pinned topology (FIXED — matches Workers A/B):

| Piece | Address (exact) |
|---|---|
| Bridge subnet (one fixed bridge, static member IPs, host kernel routes the bridge) | `172.30.51.0/24` |
| PG node 1 (`live-pg1` / `bfm-live-pg1`) | `172.30.51.11:5432` |
| PG node 2 (`live-pg2` / `bfm-live-pg2`) | `172.30.51.12:5432` |
| MiniPG per node (real jar, same port per IP) | `172.30.51.11:7779`, `172.30.51.12:7779` |
| VIP (spare IP on the bridge subnet, moved by the jar via `ip`) | `172.30.51.100` |
| BFM (`watcher.cluster-port`, `server.address=127.0.0.1`) | `127.0.0.1:9995` |
| BFM4Patroni (reserved by the dev port split — untouched, never bound here) | `127.0.0.1:9994` |
| Peer BFM | `no-pair` |

`server.pglist=172.30.51.11:5432,172.30.51.12:5432`, single `minipg.port=7779`
(distinct IPs, same port — same shape as ADR-0002, new subnet). No `ports:`
published on either member service — the host reaches container IPs directly.
`live-env.sh` loopback-only guards get a documented carve-out for this pinned
disposable bridge subnet, fail-closed everywhere else.

## Why the Python agent had to go (self-consistency trap)

ADR-0004 defined both sides of the MiniPG contract: BFM plus a
from-scratch Python agent answering the same routes. A green run then proves
self-consistency, not production correctness — any drift between the agent and
the real jar (route semantics, body shape, auth framing, side effects) is
invisible by construction.

It already cost one misattributed bug hunt: the agent answered 401 without
draining the POST body, desyncing the keep-alive connection so BFM's promote
never executed; fixed in `551eb73`, but the ambiguity was the tax. Running the
real jar removes the class: failures now implicate BFM, the jar, or PG — never
a throwaway middle layer we also wrote.

## Translation shim removed

The Python agent papered over a topology mismatch with host→service
translation (`127.0.10.x` on the host mapped to container names/ports). The
real jar has no such shim and none may be reintroduced: BFM hands the jar
host-view IPs that the jar uses LITERALLY — `RewindDTO.masterIp` /
`ReBaseUpDTO.masterIp` in rewind/rebase scripts and `primary_conninfo`. From
inside a bridge netns, `127.0.10.x` is the container itself, so peer
connections fail. The bridge subnet with routable static IPs is the fix; BFM's
`server.pglist` values are the same IPs the jar sees.

## `checkvip` manufactures state — never evidence

`MiniPGController.checkvip` lists interfaces and, when the VIP is absent,
attempts `vipUp()` itself, returning `VIP-SET:OK`. Calling it can therefore
manufacture the very state it inspects. `validate` must NEVER use `checkvip`
as VIP evidence. Prove VIP instead by read-only inspection:

(a) `ip address show` via `docker exec` on both nodes (exactly one holder),
(b) holder == current SQL MASTER (`pg_is_in_recovery()=f`),
(c) a replicated write on the master visible per `pg_stat_replication`.

## PG14 pin

Pin `postgres:14.13-bookworm` (same as the reference env). Do NOT use PG16:
the jar's `PgVersion` enum maxes out at `V14X` (`valueOf("V16X")` throws) and
jar+PG14 is the proven combo; BFM's SQL needs nothing newer. Mandatory
per-node values: `pgVersion: V14X`, `postgresBinPath`/`pgCtlBinPath:
"/usr/lib/postgresql/14/bin/" (trailing slash is load-bearing — the jar
concatenates `pgCtlBinPath + "pg_ctl"`), `postgresDataPath` to the node's
data dir. Omit Patroni-only keys (`patroniCtlBinPath`,
`patroniConfFilePath`). Other mandatory values: `"clusterManager": "bfm"`
(NOT omittable: `MiniPGHelper.java:77` calls
`getClusterManager().equals("bfm")` → null NPEs; the `"bfm"` branch is what
enables PG auto-manage), fixed test-only creds `bfm`/`bfm`, `port: 7779`,
`vipInterface` set to the container's actual interface (verify `eth0` at
runtime, do not assume), `postVipUp: /bin/true`. Jar must run with postgres
ownership of PG paths; `psql` on PATH with sane local-probe defaults.

## Bridge decision (alternatives rejected)

- Host networking is OUT: the jar sets only the port (`CustomizationBean:
  container.setPort(...)`, no bind address → wildcard `:7779`); two
  host-networked agents collide on 7779 and BFM's single-`minipg.port`
  assumption breaks.
- Keeping `127.0.10.x` tuples with bridge networking is OUT (see translation
  section above): the jar uses `masterIp` literally, and loopback inside a
  bridge netns is the container itself.
- Consequence: static IPs on one fixed bridge, no published ports, host routes
  the bridge. `9994` (BFM4Patroni) stays untouched as before.

## VIP spec (the jar does real `ip` ops)

`vip-up`/`vip-down` run
`sudo ip address add/del <vipIp>/<netmask> dev <vipInterface>` inside the
container netns, then `sudo <postVipUp>` (`MiniPGController.java:201-275`).
Image and compose MUST provide: `iproute2` + passwordless sudo for those exact
commands for the jar user, `cap_add: [NET_ADMIN]` on both member services, the
spare VIP IP above, `vipInterface: eth0` (verified at runtime),
`postVipUp: /bin/true`. Proof via `docker exec`, never `checkvip`.

## Considered Options

- Compatible Python agent per node (ADR-0004): cheapest, real `pg_ctl` ops —
  rejected (self-consistency trap above; deleted).
- Host-run PG binaries: no container isolation, host-version drift — rejected.
- Patroni-managed cluster under test with BFM observing: richest infra, but
  BFM must own failover — rejected (Patroni stack stays reference only).
- No Patroni/etcd/HAProxy in the BFM live env; no VM layer beyond container
  `NET_ADMIN` for the VIP IP; no BFM app (`app/`) changes.

Refs: #23 (this change), #18, #14, #20–#22 (verdicts from runs against the
real jar), ADRs 0001–0004, `551eb73`.
