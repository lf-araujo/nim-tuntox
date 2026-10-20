# Chunk 2 — Protocol frames + tunnel registry

## Goal

The tuntox wire protocol translated to GC-managed Nim, with unit tests.

## Files to read first

- /tmp/tuntox/main.h (PROTOCOL_* defines, protocol_frame struct)
- /tmp/tuntox/main.c lines 360-760 (send_frame, parse_lossless_packet,
  handle_frame dispatcher)
- src/tuntox/tox.nim (chunk 1's binding)

## Instructions

1. src/tuntox/protocol.nim:
   - consts: protocolMagic = 0xa26b, packet types (tcp=0x0600,
     tcpFin=0x0601, requestTunnel=0x0602, denyTunnel=0x0604,
     ackTunnel=0x0610, ping=0x0108, pong=0x0100), bufferOffset = 8.
   - `Frame` object: friendnumber, magic, packetType, connId, data: seq[byte]
     (or a flat `data` including host/port for request frames — mirror the
     C layout: request frames carry remote host as 4-byte IP + port; check
     handle_request_tunnel_frame in main.c for exact encoding).
   - `encodeFrame(f: Frame): seq[byte]` — big-endian header, data appended.
   - `decodeFrame(friend: uint32, buf: openArray[byte]): Frame` — raises
     ValueError on bad magic (0xa26a = old protocol → distinct error message).
   - No manual memory: everything seq/ref.
2. src/tuntox/tunnels.nim: `Tunnel` ref object (connId, sockfd/socket,
   friendnumber, remoteHost, remotePort), registry as
   Table[uint16, Tunnel] with add/remove; `LocalForward` ref object
   (localPort, remoteHost, remotePort, bindSock, acceptSock, forwardId,
   isAcked, created: Time) with a seq — client side bookkeeping.
3. tests/test_protocol.nim: round-trip encode/decode for each packet
   type, bad-magic rejection, old-magic error message, request-frame
   host/port encoding matches what the C server parses.

## Verification

- `PKG_CONFIG_PATH=$HOME/.local/lib64/pkgconfig nimble test` passes
  (identity + protocol tests).

## Next step

When done, call context_clear with:
- summary: "Chunk 2 done: protocol codec + tunnel registry with tests"
- instruct: "Read ~/Documents/OneDrive/Coding/nim-tuntox/impl-3.md and
  execute it."
