# Learnfold Link

Learnfold-owned distribution wrapper for the
[Alleycat](https://github.com/Schreezer/alleycat) daemon. The public npm package
and command are both named `learnfold-link`.

The wrapper delegates daemon behavior to Alleycat and adds a one-time
`learnfold-link handoff <url>` command. That command performs user-level
service setup, captures the pairing credential inside the native process, and
submits it directly to Learnfold's one-time broker.

The source directory and OS service identifiers intentionally retain the
legacy `kittylitter` name so existing installations keep their identity,
pairings, and autostart entry while the public package moves to Learnfold.

## Hermes Runs compatibility baseline

The reviewed Hermes implementation for Learnfold's durable Runs lifecycle is
[`Schreezer/hermes-agent@95574e945cea3c404e6bc36be695634c14e0b9c7`](https://github.com/Schreezer/hermes-agent/commit/95574e945cea3c404e6bc36be695634c14e0b9c7),
rebased on upstream
[`5835201de19b099d76b8e4c64afe8af90c98af05`](https://github.com/NousResearch/hermes-agent/commit/5835201de19b099d76b8e4c64afe8af90c98af05).
The upstream contribution is
[NousResearch/hermes-agent#75519](https://github.com/NousResearch/hermes-agent/pull/75519).

Learnfold Link does not silently replace a learner's Hermes installation.
Instead, the pinned Alleycat bridge probes the authenticated
`/v1/capabilities` endpoint and requires `run_submission_idempotency` plus the
rest of the Runs/session contract before accepting a mobile Hermes turn. An
older or incompatible Hermes build therefore fails closed with a compatibility
error. Until the upstream contribution ships in a Hermes release, operators
must use the immutable reviewed revision above for the Learnfold Hermes lane.
Hermes's replay registry is bounded and in-memory: it protects Alleycat's
immediate identical retry after a lost response, not retries across a Hermes
process restart.

## Cutting a release

1. Land required Alleycat changes in the public `Schreezer/alleycat` fork.
2. Pin the reviewed commit in `Cargo.toml` and refresh `Cargo.lock` with
   `./tools/scripts/update-alleycat-main.sh --learnfold-link`.
3. Verify the Hermes compatibility baseline above is either in the current
   upstream Hermes release or still available at its immutable fork revision.
4. Bump `version` in this crate's `Cargo.toml`.
5. Publish the native artifacts on `Schreezer/learnfold-link`, then publish
   the generated `learnfold-link` package to npm.
