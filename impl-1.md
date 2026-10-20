# Chunk 1 — Skeleton + toxcore binding

## Goal

A working nimble package `tuntox` whose src/tuntox/tox.nim is a c2nim-generated
binding to libtoxcore (installed in ~/.local, found via
`PKG_CONFIG_PATH=$HOME/.local/lib64/pkgconfig`), plus a smoke test that creates
a Tox instance, reads its address, and saves/loads a persistent identity.

## Files to read first

- /tmp/tuntox/main.c lines 1500-1803 (tox_new/options/save/load usage patterns)
- /tmp/c-toxcore/toxcore/tox.h (the header being translated)
- impl-plan.md (master plan)

## Instructions

1. `tuntox.nimble` — package `tuntox`, version 0.1.0, license GPL-3.0,
   srcDir src, requires nim >= 2.0. Pass pkg-config flags via
   `{.passC.}/{.passL.}` with staticExec inside the binding module.
2. Run c2nim on /tmp/c-toxcore/toxcore/tox.h (it's the installed one too:
   ~/.local/include/tox/tox.h). Use `--header` mode. Expect to hand-fix:
   - `#define` constants → Nim consts (TOX_ADDRESS_SIZE etc.)
   - enums (TOX_CONNECTION, TOX_ERR_*) → Nim enums with importc
   - callback typedefs → proc types
   - tox_iterate's void* userdata → pointer (we'll wrap with casts)
   - TOX_USER_STATUS, tox_options_* accessors
   Keep the binding mechanical/complete-enough: only what the library uses
   (tox_new/free, options, bootstrap, iterate, callbacks: friend_request,
   friend_connection_status, self_connection_status, friend_lossless_packet;
   send_lossless_packet, get_address, public key, savedata load/save,
   friend add/sendmessage not needed). Prefer trimming to the used subset
   over fighting c2nim on every corner of the header.
3. Write tests/test_identity.nim: create Tox with a temp state file —
   first run persists savedata and prints the 76-char Tox ID; second run
   loads it and the ID must be identical. Use `tox_get_savedata` +
   `tox_new` with savedata options. Run via `nimble test` (tests dir).
4. `nim r` the smoke test; verify the ID is 76 hex chars.

## Verification

- `PKG_CONFIG_PATH=$HOME/.local/lib64/pkgconfig nimble test` passes.
- Test prints identical Tox ID across two runs with the same state file.

## Next step

When this chunk is complete and verified, call context_clear with:
- summary: "Chunk 1 done: nim-tuntox skeleton + c2nim toxcore binding +
  identity persistence test passing"
- and instruct: "Read ~/Documents/OneDrive/Coding/nim-tuntox/impl-2.md and
  execute it."
