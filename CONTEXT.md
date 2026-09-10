# BFM

BFM performs PostgreSQL failover itself, using direct JDBC observations, MiniPG sidecar operations, and an optional paired BFM instance.

## Language

**Fast environment**:
A disposable host-run BFM with deterministic WireMock (MiniPG) and PG-wire (PostgreSQL) substitutes. No Docker, no live databases.
_Avoid_: mock env, unit env, regression env

**Live environment**:
A disposable PostgreSQL streaming-replication cluster with real MiniPG agents where BFM owns failover. Separate from the fast environment.
_Avoid_: docker env, integration env, realistic env

**Scenario**:
One immutable fixture set selected at `prepare` time (e.g. `healthy`). Changing scenario requires `reset` + `prepare`.
_Avoid_: profile, mode, test case

**Stub**:
An out-of-process substitute at a real network boundary (MiniPG HTTP, PG wire protocol, peer BFM HTTP). Never an in-process mock.
_Avoid_: mock, fake, simulator

**Validate**:
The readiness gate asserting stubs, fresh BFM observations, and expected `bfm_status.json` state for the prepared scenario.
_Avoid_: test, verify, check
