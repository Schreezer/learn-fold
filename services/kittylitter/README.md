# Learnfold Link

Learnfold-owned distribution wrapper for the
[Alleycat](https://github.com/dnakov/alleycat) daemon. The public npm package
and command are both named `learnfold-link`.

The wrapper delegates daemon behavior to Alleycat and adds a one-time
`learnfold-link handoff <url>` command. That command performs user-level
service setup, captures the pairing credential inside the native process, and
submits it directly to Learnfold's one-time broker.

The source directory and OS service identifiers intentionally retain the
legacy `kittylitter` name so existing installations keep their identity,
pairings, and autostart entry while the public package moves to Learnfold.

## Cutting a release

1. Push the alleycat changes to `dnakov/alleycat`.
2. Keep the `alleycat` dependency on `branch = "main"` and refresh it with
   `./tools/scripts/update-alleycat-main.sh --learnfold-link`.
3. Bump `version` in this crate's `Cargo.toml`.
4. Tag `vX.Y.Z` on `Schreezer/learn-fold`. The root `release.yml` workflow
   builds the native artifacts and publishes `learnfold-link` to npm.
