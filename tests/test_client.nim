## Client-side tunnel machinery without a tox network: a real Tox
## instance stands in for the remote server (friend requests queue
## offline), a send hook captures what the client would put on the wire,
## and ACK/DENY frames are crafted by hand to drive the handshake.
##
## Test bodies that install a send hook live inside a `run()` proc:
## unittest's `test` template expands inline at module scope, which
## makes the gcsafe analysis treat captured vars as globals.

import std/[net, os, unittest]
import tuntox/[client, protocol, tox, tunnels]

let stateDir = getTempDir() / "nim_tuntox_client_test"

func forwardIdData(id: uint32): seq[byte] =
  @[byte(id shr 24), byte(id shr 16), byte(id shr 8), byte(id)]

suite "tunnel client":
  test "identity persists across restarts":
    removeDir(stateDir)
    let remote = newTox()
    let c1 = newTunnelClient(stateDir, "sekrit", remote.address)
    check c1.toxId().len == 76
    let c2 = newTunnelClient(stateDir, "sekrit", remote.address)
    check c2.toxId() == c1.toxId()
    check c2.friendnumber == c1.friendnumber # friend found, not re-added

  test "addForward binds, accept requests a tunnel, ack wires it up":
    proc run() =
      let remote = newTox()
      let c = newTunnelClient(stateDir, "sekrit", remote.address)

      var sent: seq[seq[byte]] = @[]
      c.sendHook = proc (cl: TunnelClient; friendnumber: uint32;
          packet: seq[byte]): bool =
        sent.add(packet)
        true

      let fwd = c.addForward(0, "127.0.0.1", 8080'u16)
      check fwd.forwardId != 0
      let localPort = fwd.bindSock.getLocalAddr()[1]

      # a local connection arrives: the client must ask for a tunnel
      let peer = newSocket()
      peer.connect("127.0.0.1", Port(localPort))
      c.poll()
      check sent.len == 1
      let req = parseRequestTunnel(decodeFrame(c.friendnumber, sent[0]))
      check req.host == "127.0.0.1"
      check req.port == 8080
      check req.forwardId == fwd.forwardId
      check fwd.acceptSock != nil
      check not fwd.isAcked

      # hand-craft the server's ACK: connId = tunnel id, data = forward id
      c.tox.onLosslessPacket(c.friendnumber, encodeFrame(Frame(
        friendnumber: c.friendnumber, magic: protocolMagic,
        packetType: packetTypeAckTunnel, connId: 42,
        data: forwardIdData(fwd.forwardId))))
      check fwd.isAcked
      check c.tunnels.len == 1
      let tun = c.tunnels.get(42)
      check tun != nil
      check tun.sock == fwd.acceptSock # forward keeps the link for close

      # local peer sends: the bytes go out as a TCP frame on tunnel 42
      peer.send("hello")
      c.poll()
      check sent.len == 2
      let tcp = decodeFrame(c.friendnumber, sent[1])
      check tcp.packetType == packetTypeTcp
      check tcp.connId == 42
      check cast[string](tcp.data) == "hello"

      # server sends back: the bytes reach the local peer
      c.tox.onLosslessPacket(c.friendnumber, encodeFrame(Frame(
        friendnumber: c.friendnumber, magic: protocolMagic,
        packetType: packetTypeTcp, connId: 42,
        data: cast[seq[byte]]("hi there"))))
      check peer.recv(8) == "hi there"

      # local peer hangs up: TCP_FIN goes out, the tunnel is dropped and
      # the forward is ready for the next connection
      peer.close()
      c.poll()
      check sent.len == 3
      let fin = decodeFrame(c.friendnumber, sent[2])
      check fin.packetType == packetTypeTcpFin
      check fin.connId == 42
      check c.tunnels.len == 0
      check fwd.acceptSock == nil
      check not fwd.isAcked

      peer.close()

  test "deny closes the pending socket and frees the forward":
    proc run() =
      let remote = newTox()
      let c = newTunnelClient(stateDir, "sekrit", remote.address)

      var sent: seq[seq[byte]] = @[]
      c.sendHook = proc (cl: TunnelClient; friendnumber: uint32;
          packet: seq[byte]): bool =
        sent.add(packet)
        true

      let fwd = c.addForward(0, "10.1.2.3", 22'u16)
      let localPort = fwd.bindSock.getLocalAddr()[1]

      let peer = newSocket()
      peer.connect("127.0.0.1", Port(localPort))
      c.poll()
      check sent.len == 1

      # hand-craft the server's DENY: connId = 0, data = forward id
      c.tox.onLosslessPacket(c.friendnumber, encodeFrame(Frame(
        friendnumber: c.friendnumber, magic: protocolMagic,
        packetType: packetTypeDenyTunnel, connId: 0,
        data: forwardIdData(fwd.forwardId))))
      check fwd.acceptSock == nil
      check not fwd.isAcked
      check c.tunnels.len == 0

      # the forward accepts again and re-requests
      let peer2 = newSocket()
      peer2.connect("127.0.0.1", Port(localPort))
      c.poll()
      check sent.len == 2
      check parseRequestTunnel(
        decodeFrame(c.friendnumber, sent[1])).forwardId == fwd.forwardId

      peer.close()
      peer2.close()
