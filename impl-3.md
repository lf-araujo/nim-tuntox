# Chunk 3 — Server side

## Goal

The tuntox server translated: bootstrap into the DHT, accept friend
requests gated by a shared secret, accept tunnel requests, relay TCP.

## Files to read first

- /tmp/tuntox/main.c lines 760-1100 (accept_friend_request,
  handle_friend_request, connection status callbacks, do_tox)
- /tmp/tuntox/main.c lines 478-640 (handle_request_tunnel_frame,
  handle_client_tcp_frame, handle_client_tcp_fin_frame)
- /tmp/tuntox/tox_bootstrap.h (static node list — take ~10 entries)
- src/tuntox/tox.nim, src/tuntox/protocol.nim, src/tuntox/tunnels.nim

## Instructions

1. src/tuntox/bootstrap.nim: const list of (key, host, port) DHT nodes
   from tox_bootstrap.h (a handful is enough) + `bootstrapInto(tox)`.
2. src/tuntox/server.nim: `TunnelServer` ref object wrapping the Tox
   instance + tunnel Table + shared secret. API:
   - `newTunnelServer(stateDir, sharedSecret)` — loads/persists identity
     (chunk 1 mechanism), bootstraps.
   - `toxId(s): string` — 76 hex chars.
   - `poll(s)` — one tox_iterate + selector event handling on open tunnel
     sockets: read local TCP → sendFrame(tcp), remote frame → write local
     TCP. Non-blocking, driven by the caller (editor tick).
   - friend request callback: accept only when message == sharedSecret
     (C: strncmp on TOX_MAX_FRIEND_REQUEST_LENGTH); reject otherwise.
   - REQUESTTUNNEL: connect() to requested host:port (non-blocking),
     reply ACKTUNNEL with the connid; DENYTUNNEL on connect failure.
   - TCP frame: write to the tunnel's socket; FIN: close + drop tunnel.
   - Use std/selectors + std/net sockets in non-blocking mode; keep a
     single Selector per server. No globals — everything on the object.
3. tests/test_server.nim: unit-test the request/ack path with a fake
   friendnumber (no network): feed a decoded REQUESTTUNNEL frame into the
   handler with a listener socket on localhost, expect ACK and a working
   relay both directions.

## Verification

- `nimble test` passes; the fake-friend relay test moves bytes through.

## Next step

When done, call context_clear with:
- summary: "Chunk 3 done: server side (friend auth, tunnel accept, TCP relay)"
- instruct: "Read ~/Documents/OneDrive/Coding/nim-tuntox/impl-4.md and
  execute it."
