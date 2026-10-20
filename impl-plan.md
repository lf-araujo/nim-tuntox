# nim-tuntox — tuntox translated to a Nim library

## Goal

Translate [gjedeer/tuntox](https://github.com/gjedeer/tuntox) (GPLv3, C) into a
**Nim library** — no CLI — covering only the functionality wkbenchless uses on
the `dag-citation-ledger` branch (src/wkbtox.nim):

- **server**: persistent Tox identity in a state dir, expose own Tox ID,
  accept friend requests authorized by a shared secret, accept tunnel
  requests to `host:port`, relay TCP data both ways
- **client**: given a remote Tox ID + remote port, open a local TCP
  listener and forward it through the tunnel
- **poll()**: non-blocking iteration so an editor tick can drive it

Everything is GC-managed Nim (refs, seqs, Tables) — no calloc/free, no
uthash/utlist/utarray, no cJSON (std/json instead). Dropped from tuntox:
socks5, pipe/stdin mode, ping mode, file transfer, hostname allowlists,
daemon/syslog.

**Scope boundary**: toxcore itself (DHT/crypto, TokTok/c-toxcore) stays a C
library, bound via a c2nim-generated binding and (later) vendored+built by the
package — that vendoring is what solves mac/windows distribution. Translating
toxcore to Nim is out of scope.

**License**: GPLv3 (derived from tuntox). Note for wkbenchless (MIT): linking
against this makes combined *binaries* GPL; source can stay MIT.

Reference C sources live in /tmp/tuntox (clone of gjedeer/tuntox).
toxcore v0.2.19 is built+installed in ~/.local (pkg-config toxcore works;
`~/.local/bin/DHT_bootstrap` enables hermetic loopback tests).

## Chunks

1. **Skeleton + toxcore binding** — nimble package, c2nim on tox.h →
   src/tuntox/tox.nim, fix until it compiles; smoke test: create a Tox,
   get the address, save/load identity. *(impl-1.md)*
2. **Protocol frames + tunnel registry** — the 8-byte frame header
   (magic 0xa26b, packet type, connid, length), encode/decode, tunnel
   table as a Nim Table; unit tests for the codec. *(impl-2.md)*
3. **Server side** — bootstrap, friend-request handling with shared
   secret, REQUESTTUNNEL/ACK/TCP/FIN handling, TCP sockets via
   std/selectors; port of main.c server logic. *(impl-3.md)*
4. **Client side** — local port forward (the -L semantics), tunnel
   request + ack wait, bridging; the public library API
   (TunnelServer/TunnelClient objects + poll). *(impl-4.md)*
5. **Integration test + publish** — hermetic test using local
   DHT_bootstrap (server+client Tox instances connect over loopback,
   open a tunnel, echo data); README; push to github.com/lf-araujo. *(impl-5.md)*
