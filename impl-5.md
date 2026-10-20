# Chunk 5 — Integration test + publish

## Goal

Prove the whole stack hermetically, then push to GitHub.

## Files to read first

- impl-plan.md (license note), all src/tuntox/*.nim
- ~/.local/bin/DHT_bootstrap --help (local bootstrap node)

## Instructions

1. tests/test_integration.nim (tagged or skipped when no network):
   - start ~/.local/bin/DHT_bootstrap on a localhost port (startProcess)
   - server = newTunnelServer(tmpA, "sekrit"); bootstrap it to 127.0.0.1
     (add an optional `bootstrap(server, host, port)` API for tests)
   - client = newTunnelClient(tmpB, "sekrit", server.toxId)
   - client.addForward(freeLocalPort, "127.0.0.1", echoServerPort)
   - poll both in a loop (deadline ~60s) until connected; then a TCP
     echo server on the "remote" side must echo through the tunnel.
   - Assert round-trip data; then FIN and clean shutdown.
2. README.md: what it is (tuntox → Nim library, GPLv3), the API with a
   short example, the toxcore dependency story (pkg-config toxcore;
   `nimble toxcore` task that clones+builds c-toxcore into vendor/ when
   missing — implement that task), mac/windows notes (vendored build).
3. Remove impl-*.md (keep impl-plan.md if useful as ROADMAP), tidy
   .gitignore (nimcache, vendor/), commit.
4. `gh repo create lf-araujo/nim-tuntox --public --source . --push`
   (user's repos are public; this push was explicitly requested).

## Verification

- `nimble test` green including the integration test.
- `gh repo view lf-araujo/nim-tuntox` shows the pushed commits.

## Next step

Report back: repo URL, test status, and the follow-up (wire into
wkbenchless as a nimble dependency replacing the tuntox child in
src/wkbtox.nim — separate task).
