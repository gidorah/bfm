# Mirror the bfm4patroni fast lifecycle with IDE-owned BFM primary

BFM needs the same one-command muscle memory (`prepare → start[-dependencies] → validate → status/logs → stop → reset`) without breaking the existing bare-config `local-*` flow, and scheduler timing makes pausing under a debugger timing-sensitive.

## Scope

Fast environment

## Decision

Add `tools/fast-env/fast-env.sh` plus `just fast-*` wrappers; keep `just local-*` and the existing `BFM — local cluster` F5 config untouched. Add a separate `BFM — fast environment` F5 config pointing at `_work-tmp/fast-env/` (config + CWD). `start-dependencies` + the new F5 config is the primary debug loop; helper-owned `start`/`validate` is the secondary green-check. Scenarios are lifecycle-immutable; `validate-dependencies` covers the IDE-owned case (and still verifies the IDE process's config/CWD identity — a listener on 9995 alone is insufficient).
