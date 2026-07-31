# Learnfold Link

Learnfold-owned distribution wrapper for the
[Alleycat](https://github.com/Schreezer/alleycat) daemon. The public npm package
and command are both named `learnfold-link`.

The wrapper delegates daemon behavior to Alleycat and adds a one-time
`learnfold-link handoff <url>` command. That command performs user-level
service setup, enables Hermes' authenticated loopback API for the active
profile, captures the pairing credential inside the native process, and
submits it directly to Learnfold's one-time broker. The API key remains in the
Hermes profile's local `.env` file and is never sent to Learnfold.

The source directory and OS service identifiers intentionally retain the
legacy `kittylitter` name so existing installations keep their identity,
pairings, and autostart entry while the public package moves to Learnfold.

## Cutting a release

1. Land required Alleycat changes in the public `Schreezer/alleycat` fork.
2. Pin the reviewed commit in `Cargo.toml`, then resolve that exact revision
   with `cargo update --manifest-path services/kittylitter/Cargo.toml -p alleycat --precise <commit>`.
   The general `update-alleycat-main.sh` build helper intentionally preserves
   explicit Learnfold Link pins.
3. Bump `version` in this crate's `Cargo.toml`.
4. Publish the native artifacts on `Schreezer/learnfold-link`, then publish
   the generated `learnfold-link` package to npm.
