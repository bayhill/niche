# MediaRemoteAdapter (vendored)

Upstream: https://github.com/ungive/mediaremote-adapter (BSD 3-Clause, see `LICENSE`)
Commit: `65714990277cb4d0415ebaf7fff6be3229362b28` (2026-11-20, "Define the bundle ID in a single place")

Vendored unchanged: `bin/mediaremote-adapter.pl`, `include/`, `src/` (adapter framework sources and the
`MediaRemoteAdapterTestClient` used by the `test` command), `LICENSE`. Not vendored: CMake files, editor config,
dev scripts, README badges.

`build.sh <outdir>` replaces the upstream CMake build, so that building Notcher does not need CMake. It compiles with the Xcode
toolchain's `clang` (universal arm64 + x86_64) and writes:

- `<outdir>/MediaRemoteAdapter.framework` - versioned framework, loaded by the script, never linked. The test client
  is placed inside it at `Versions/A/MediaRemoteAdapterTestClient` (symlinked at the framework root) so
  `scripts/bundle.sh` ships it without changes.
- `<outdir>/mediaremote-adapter.pl`

Invocation (paths must be absolute):

    /usr/bin/perl mediaremote-adapter.pl /abs/MediaRemoteAdapter.framework [/abs/MediaRemoteAdapterTestClient] get|stream|send N|test

To update: clone upstream, copy `bin/mediaremote-adapter.pl`, `include/`, `src/` and `LICENSE` over these, update the
commit above, and add any new `src/adapter/*.m` (they are globbed) or new source directories to `build.sh`.
