# Chunk 4 — Client side + public API

## Goal

The tuntox client translated (the -L local port forward), and the final
library API surface wkbenchless's src/wkbtox.nim will call.

## Files to read first

- /tmp/tuntox/client.c (whole file — client_mode, client_local_port_mode,
  forward_local_port, accept loop, tunnel request/ack handshake)
- /tmp/tuntox/main.c lines 1100-1250 (the select loop's client branches)
- src/tuntox/server.nim (mirror its structure)

## Instructions

1. src/tuntox/client.nim: `TunnelClient` ref object — Tox instance,
   remote Tox ID, seq[LocalForward] (chunk 2), Selector.
   - `newTunnelClient(stateDir, sharedSecret, remoteToxId)` — identity,
     bootstrap, send friend request carrying the shared secret.
   - `addForward(c, localPort, remoteHost, remotePort)` — bind local
     listener; on accept: hold the socket, send REQUESTTUNNEL with a
     forwardId; on ACKTUNNEL matching forwardId: attach socket to tunnel.
   - `poll(c)` — tox_iterate + selector: local socket readable → frame
     out; remote TCP frame → write into the accepted socket; FIN → close.
   - Retries/timeouts: mirror client.c (request re-send while unacked).
2. src/tuntox.nim (or tuntox.nim) — the public module: export
   TunnelServer, TunnelClient, newTunnelServer, newTunnelClient, toxId,
   addForward, poll. This is the whole API; document each proc with a
   doc comment showing the wkbenchless usage (server: poll each tick,
   write toxId to a file; client: addForward(6543, "127.0.0.1", 6543)).
3. tests/test_client.nim: fake-server test — a plain TCP listener standing
   in for the remote end is NOT possible (frames go over tox), so unit
   test the forward bookkeeping: addForward binds the local port,
   request frame is produced, ack completes the wiring against a
   hand-crafted ACK frame.

## Verification

- `nimble test` passes; local listener binds, handshake state machine
  transitions correctly.

## Next step

When done, call context_clear with:
- summary: "Chunk 4 done: client side + public API"
- instruct: "Read ~/Documents/OneDrive/Coding/nim-tuntox/impl-5.md and
  execute it."
