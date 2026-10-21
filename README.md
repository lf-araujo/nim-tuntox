# nim-tuntox

TCP tunnels over the [Tox](https://tox.chat) network, as an embeddable
[Nim](https://nim-lang.org) library — [gjedeer/tuntox](https://github.com/gjedeer/tuntox)
translated from C. No CLI, no globals, no threads: a host application drives
everything from its own event loop via `poll()`.

Derived from tuntox, so licensed under the **GPLv3** (see `LICENSE.md`).

## What it does

- **Server** — persistent Tox identity in a state dir, exposes its Tox ID,
  accepts friend requests only when they carry a shared secret, answers
  tunnel requests to `host:port` with ACK/DENY, relays TCP data both ways.
- **Client** — given the server's Tox ID, forwards a local TCP port through
  the tunnel (`tuntox -L` semantics; the listener binds loopback only).
- **`poll()`** — one non-blocking iteration; call it every
  `iterationInterval()` milliseconds from your tick.

Dropped from tuntox (out of scope): socks5, pipe/stdin mode, ping mode,
file transfer, hostname allowlists, daemon/syslog.

## Example

```nim
import tuntox

# server: share the Tox ID (76 hex chars) with your clients
let server = newTunnelServer("/var/lib/myapp", "hunter2")
echo server.toxId()
while running:
  server.poll()
  sleep(server.iterationInterval())

# client: forward local port 6543 to 127.0.0.1:6543 on the server
let client = newTunnelClient(getTempDir() / "tox", "hunter2", serverToxId)
discard client.addForward(6543, "127.0.0.1", 6543)
while running:
  client.poll()
  sleep(client.iterationInterval())
```

Both sides persist their identity in `<stateDir>/tox_save`, so the Tox ID
(and the friend list) survive restarts. A local peer may connect to the
forward before the Tox connection is up — the library holds the connection
in the backlog and the data flows once the tunnel is established.

## The toxcore dependency

toxcore (the DHT/crypto layer) stays a C library —
[TokTok/c-toxcore](https://github.com/TokTok/c-toxcore) v0.2.19, found via
`pkg-config toxcore` at compile time. Translating toxcore itself is out of
scope.

- **Linux**: install `libtoxcore-dev` (Debian/Ubuntu) or `toxcore-devel`
  (Fedora), or use the vendored build below.
- **Vendored build**: `nimble toxcore` clones c-toxcore v0.2.19 (with its
  `cmp` submodule) into `vendor/`, builds it with cmake, and installs it
  under `vendor/` — then point pkg-config at it:

  ```sh
  nimble toxcore
  export PKG_CONFIG_PATH=$PWD/vendor/lib64/pkgconfig:$PKG_CONFIG_PATH
  nimble test
  ```

  (On Debian-style systems the install lands in `vendor/lib/pkgconfig`
  instead; the task prints the right path.)
- **macOS / Windows**: no toxcore in homebrew-core or vcpkg releases —
  use the vendored build (`nimble toxcore` needs cmake, a C compiler, and
  libsodium; on Windows, mingw builds are confirmed easy upstream). The
  binding links the static lib, so the result is a self-contained binary.

## Tests

```sh
nimble test
```

23 tests, including a hermetic end-to-end integration test: a real
`TunnelServer` and `TunnelClient` connect over a loopback Tox network
(local `DHT_bootstrap` node, no internet) and echo data through a tunnel.
The integration test skips itself when `~/.local/bin/DHT_bootstrap`
(built by c-toxcore's `-DDHT_BOOTSTRAP=ON`) is not installed.

## License

GPLv3, as a translation of tuntox. Note for MIT-licensed consumers (e.g.
wkbenchless): linking this library into your binary makes the combined
*binary* GPL; your source can stay MIT.
