# Vendored Rust compatibility crates

These copies keep Litter's existing transport APIs compatible with the Codex 0.144.6 dependency
graph. They are source copies of the named crates.io releases and retain their upstream licenses.

- `iroh-0.98.1`: keeps Litter on the existing Iroh API. Its `blake3` lower bound is relaxed from
  1.8.3 to 1.8.2 to match Codex/Starlark's exact pin, and two hash byte accesses use `as_bytes()`
  (available in 1.8.2) instead of `as_slice()`.
- `sqlx-0.9.0` and `sqlx-macros-core-0.9.0`: SQLite-only facades. Optional MySQL and PostgreSQL
  dependency blocks are removed so Cargo does not resolve their unused SHA dependency families
  into the same lockfile as Litter's Iroh/SSH stack. The SQLite, macros, and migration surfaces used
  by Codex are unchanged.

When upgrading Codex, first try removing these patches. If upstream dependencies resolve together,
delete the corresponding local overrides rather than carrying the copies forward.
