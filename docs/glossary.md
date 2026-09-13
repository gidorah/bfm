# BFM glossary (draft)

> **Status: Draft.** Canonical names, preferred replacements, and reserved future terms remain proposals until their corresponding refactors are accepted and implemented. Current code and wire values remain authoritative for current behavior.

This glossary defines the terms proposed for describing BFM. It also maps misleading names in the current code and wire formats to preferred terms for future work.

Current names remain part of the implementation until a deliberate refactor changes them. Use the preferred terms in new documentation, issues, tests, and code.

## Naming rules

- Qualify every kind of leadership. Use `controller leader` and `etcd Raft leader`, never the unqualified word `leader`.
- Use `primary` and `replica` for PostgreSQL replication roles. Avoid `master` and `slave` except when quoting current code or wire values.
- Use `instance` for a running BFM or PostgreSQL process. Use `node` for its stable identity in a cluster. Avoid `server` when either meaning would fit.
- Distinguish an observation from an established fact. A BFM observation of a PostgreSQL primary may be stale, incomplete, or conflicting.
- Keep controller authority independent from PostgreSQL replication roles. The controller leader and PostgreSQL primary may run on different nodes.

## Canonical terms

### Control plane

**BFM instance**

A running BFM application on one node.

**BFM node**

The stable identity and configuration of a BFM instance in a BFM cluster.

**Controller leader**

The BFM instance currently authorized to admit and advance cluster-management operations. Controller leadership does not determine which PostgreSQL node is primary.

**Controller follower**

A BFM instance that does not hold controller authority. It may observe the cluster, publish its own status, serve read requests, and forward commands to the controller leader.

**Controller term**

A monotonically ordered period of controller leadership. Operations and actuator commands can carry the term so recipients reject commands from a former controller leader.

**BFM pair**

The current deployment model in which one BFM communicates with one optional peer BFM. This term describes the existing two-instance topology, not the proposed distributed-controller model.

### PostgreSQL plane

**PostgreSQL node**

A configured PostgreSQL instance with a stable cluster identity. Its identity must distinguish separate instances that run on the same host.

**PostgreSQL primary**

A PostgreSQL instance that is not in recovery and may accept writes. This role is independent from controller leadership.

**PostgreSQL replica**

A PostgreSQL instance in recovery that receives or replays WAL from an upstream PostgreSQL instance.

**Cascading replica**

A PostgreSQL replica that also streams WAL to one or more downstream replicas.

**Observed PostgreSQL primary**

The PostgreSQL node that a particular observation identifies as primary. This is evidence, not controller authority or proof that the cluster has only one writable primary.

**Promotion candidate**

The PostgreSQL replica selected for validation as the possible next primary. Selection does not authorize promotion.

**Former primary**

A PostgreSQL node that previously ran as primary and must be reconciled before it can rejoin the cluster.

### Operations and state

**Failover**

An unplanned operation that replaces an unavailable PostgreSQL primary with an eligible replica.

**Switchover**

A planned operation that changes the PostgreSQL primary while the current primary remains available for an orderly handoff.

**Promotion**

The PostgreSQL action that changes a replica into a primary. Promotion is one step within failover or switchover.

**Fencing**

The enforced exclusion of a stale actor. Always qualify it as controller fencing or PostgreSQL primary fencing.

**Controller fencing**

The mechanism that prevents a former controller leader from advancing operations or issuing accepted actuator commands.

**PostgreSQL primary fencing**

The mechanism that prevents a former or isolated PostgreSQL primary from accepting writes before another node is promoted.

**Rejoin**

The controlled operation that makes a former primary or detached replica follow the current PostgreSQL primary again.

**Rewind**

A rejoin method that uses `pg_rewind` to reconcile divergent PostgreSQL timelines.

**Rebuild**

A destructive rejoin method that recreates a PostgreSQL replica from a new base backup. Prefer this term over `rebase` when that is the actual operation.

**Cluster health**

A derived assessment of current PostgreSQL availability, redundancy, and observation freshness. It is separate from an operation's progress.

**Operation phase**

The durable progress of one admitted cluster-management operation, such as pending, fencing, promoting, verifying, completed, failed, or outcome unknown.

**Published status**

A timestamped, immutable view derived from observations, controller authority, policy, and operation state for the UI and other readers.

**MiniPG agent**

The node-local process that performs PostgreSQL, replication, filesystem, and virtual IP actions requested by BFM.

**Virtual IP**

The movable network address intended to route clients to the PostgreSQL primary. Virtual IP ownership does not prove that another PostgreSQL node cannot accept writes.

## Current-to-preferred refactor map

| Current name | Current meaning | Preferred name | Refactor note |
|---|---|---|---|
| `PostgresqlServer` | Mutable representation of a configured PostgreSQL instance, including observations, credentials, and a JDBC connection | `PgNode` for identity and `PgObservation` for observed state | Split identity from observations and I/O rather than applying a literal class rename. |
| `masterServer` | PostgreSQL node that the current BFM state identifies as primary | `pgPrimary` | Use `observedPgPrimary` where the value is explicitly unverified or local to one observation. |
| `masterServerLastWalPos` | Last recorded WAL position for the node believed to be primary | `lastObservedPrimaryLsn` | Store acquisition time and evidence quality with the LSN. |
| `isMaster` | Result derived from `pg_is_in_recovery()` | `isPrimary` | A boolean alone cannot express unknown or failed observation. |
| `MASTER` | Primary with at least one row in `pg_stat_replication` | `PRIMARY_WITH_REPLICA` | The current value combines database role and replication topology. Prefer separate fields. |
| `MASTER_WITH_NO_SLAVE` | Primary with no rows in `pg_stat_replication` | `PRIMARY_WITHOUT_REPLICA` | Prefer `role = PRIMARY` plus a separate redundancy assessment. |
| `SLAVE` | Replica with no downstream rows in `pg_stat_replication` | `REPLICA` | Upstream connectivity is checked elsewhere and should be a separate observation. |
| `SLAVE_WITH_SLAVE` | Replica with at least one downstream replication row | `CASCADING_REPLICA` | Prefer `role = REPLICA` plus explicit upstream and downstream relationships. |
| `hasSlave` | Whether `pg_stat_replication` returned at least one row | `hasDownstreamReplica` | This does not prove that a downstream replica is healthy or caught up. |
| `getHasMasterServer()` | Whether `pg_stat_wal_receiver` returned at least one row | `hasWalReceiver` or `observedUpstream` | The current result does not establish an authoritative primary. |
| `findLeader()` | Chooses the node with the highest observed timeline and WAL text | `findMostAdvancedPgNode()` | Replace the comparison rules before treating the result as eligible for an operation. |
| `findLeaderMaster()` | Chooses among nodes classified as PostgreSQL primary | `selectSurvivingPgPrimary()` | The result needs explicit split-brain policy and verified evidence. |
| `findLeaderSlave()` | Chooses among nodes classified as `SLAVE` using observed timeline and WAL text; it excludes `SLAVE_WITH_SLAVE` | `findMostAdvancedPgReplica()` | Keep candidate discovery separate from promotion eligibility. |
| `selectNewMaster()` | Returns the node that `failover()` passes to MiniPG promotion. The normal path selects the highest-priority nonzero `SLAVE`; two-node branches can return a `MASTER_WITH_NO_SLAVE` using priority or `findLeader()` | `selectPromotionCandidate()` | Validate the exact selected candidate and its current role before promotion. |
| `leaderMaster` | Local variable for a PostgreSQL primary chosen to survive a multiple-primary condition | `survivingPgPrimary` | Avoid `leader`, which suggests controller authority. |
| `leaderSlave` | Local variable for the replica judged most advanced | `mostAdvancedPgReplica` | This is evidence used during candidate selection, not leadership. |
| `isMasterBfm` | Whether this BFM currently considers itself authorized to execute operations | `isControllerLeader` | In the current system peer liveness can set this flag; the preferred name does not imply that the authority mechanism is safe. |
| Active BFM | BFM allowed through active-only gates for PostgreSQL topology decisions and mutations | Controller leader | Preserve `Active` only while compatibility responses require it. Some administrative mutations are not active-gated. |
| Passive BFM | BFM that mirrors the active peer's saved status and is excluded from active-only PostgreSQL topology operations | Controller follower | Pause, resume, and mail-notification endpoints can still mutate local state on a passive BFM. |
| `pairStatus` | Reported reachability or active/passive state of the configured peer BFM | `peerControllerStatus` | Replace the string values with a typed observation. Peer reachability must not grant authority. |
| `splitBrainMaster` | PostgreSQL primary selected for stopping when multiple primaries are observed | `pgPrimaryToFence` | The current name does not say whether the node survives or is stopped. Confirm the intended action at assignment sites. |
| `isExMaster` | Process-local marker assigned to the first node observed with status `MASTER` while no node is marked | `isInitialObservedPgPrimary` if the behavior is retained | The flag is not set for `MASTER_WITH_NO_SLAVE`, transferred after promotion, or persisted. Replace it with recorded topology evidence if the controller needs primary history. |
| `rebaseUp()` | MiniPG operation that rebuilds and rejoins a PostgreSQL replica | `rebuildReplica()` | Confirm the MiniPG wire contract before changing the endpoint name. |
| `rewindStarted` | Mutable flag used to suppress another rewind attempt | `rejoinOperation` | Replace the boolean with an operation identifier and phase. |
| `clusterStatus` | Mix of health assessments, failover progress, and enum values unused by production code | `clusterHealth` plus `activeOperation` | `FAILOVER` is used as operation progress. `SWITCHOVER` is declared but the current switchover workflow never assigns it. |
| `bfm_status.json` | Published status, peer synchronization, a copied pause value, and historical WAL fallback | `publishedStatus` plus `operationState` | A passive BFM copies the active peer's snapshot, but pause commands and controller authority are not propagated through the file. |
| Watch strategy `A` or `availability` | BFM may perform configured automatic recovery actions | `AUTOMATIC` | Keep the wire value until CLI and REST compatibility can change together. |
| Watch strategy `M` or `manual` | Intended to suppress automatic failover and repair while BFM continues observing | `MANUAL` | The scheduler checks this value inconsistently, including Java string identity comparisons, so manual mode does not reliably suppress every automatic action. Define and enforce the actions permitted in this mode. |

## Reserved future terms

These terms describe the proposed distributed-controller design. They do not describe the current application.

**etcd cluster**

The quorum-backed coordination store used by BFM instances. It is separate from the BFM cluster and PostgreSQL cluster.

**etcd member**

One process participating in the etcd Raft cluster. An etcd member is not necessarily a BFM node or PostgreSQL node.

**etcd Raft leader**

The etcd member currently coordinating Raft log replication. BFM does not select or target this member as its controller leader.

**Controller lease**

The expiring etcd-backed claim used to elect one controller leader. Its loss removes controller authority but does not change the PostgreSQL primary.

**PostgreSQL topology generation**

A monotonically ordered version of the intended PostgreSQL primary and replication topology. It changes through a controlled topology operation, not through controller election alone.

**Authoritative cluster state**

The controller-owned desired state and durable operation records stored in etcd. Node observations and published status are separate records.
