## Server-side tunnel machinery without a tox network: a fake friend
## number feeds frames straight into the tox callbacks, and a send hook
## captures what the server would put on the wire. A plain TCP listener
## stands in for the forwarded service.
##
## Test bodies that install a send hook live inside a `run()` proc:
## unittest's `test` template expands inline at module scope, which
## makes the gcsafe analysis treat captured vars as globals.

import std/[net, os, strutils, unittest]
import tuntox/[protocol, server, tunnels]

let stateDir = getTempDir() / "nim_tuntox_server_test"

suite "tunnel server":
  test "friend requests are gated by the shared secret":
    removeDir(stateDir)
    let s = newTunnelServer(stateDir, "sekrit")
    check s.toxId().len == 76
    check not s.acceptFriend(repeat('1', 64), "wrong secret")
    check s.acceptFriend(repeat('2', 64), "sekrit")
    check not s.acceptFriend(repeat('2', 64), "sekrit") # already a friend

  test "identity persists across restarts":
    let s1 = newTunnelServer(stateDir, "sekrit")
    let id1 = s1.toxId()
    let s2 = newTunnelServer(stateDir, "sekrit")
    check s2.toxId() == id1

  test "request -> ack -> relay both directions -> fin":
    proc run() =
      # a TCP listener standing in for the forwarded service
      let service = newSocket()
      service.bindAddr(Port(0), "127.0.0.1")
      service.listen()
      let servicePort = service.getLocalAddr()[1]

      var sent: seq[seq[byte]] = @[]
      let s = newTunnelServer(stateDir, "sekrit")
      s.sendHook = proc (srv: TunnelServer; friendnumber: uint32;
          packet: seq[byte]): bool =
        sent.add(packet)
        true

      # fake friend #7 asks for a tunnel to the service
      s.tox.onLosslessPacket(7'u32, encodeFrame(
        makeRequestTunnel(7'u32, "127.0.0.1", servicePort.uint16,
          0xfeedface'u32)))
      check s.tunnels.len == 1
      s.poll()
      check sent.len == 1
      let ack = decodeFrame(7'u32, sent[0])
      check ack.packetType == packetTypeAckTunnel
      check ack.connId == s.tunnels.get(ack.connId).connId
      check ack.data == @[byte 0xfe, 0xed, 0xfa, 0xce] # forward id echoed

      # the service sees the connection
      var conn: Socket
      service.accept(conn)

      # client -> service: TCP frame in, bytes out the service socket
      s.tox.onLosslessPacket(7'u32, encodeFrame(
        Frame(friendnumber: 7, magic: protocolMagic,
          packetType: packetTypeTcp, connId: ack.connId,
          data: @[byte 1, 2, 3])))
      check conn.recv(3) == "\x01\x02\x03"

      # service -> client: bytes in, TCP frame out to friend #7
      conn.send("pong")
      s.poll()
      check sent.len == 2
      let tcp = decodeFrame(7'u32, sent[1])
      check tcp.packetType == packetTypeTcp
      check tcp.connId == ack.connId
      check tcp.data == cast[seq[byte]]("pong")

      # a frame from another friend must not touch the tunnel
      s.tox.onLosslessPacket(8'u32, encodeFrame(
        Frame(friendnumber: 8, magic: protocolMagic,
          packetType: packetTypeTcp, connId: ack.connId,
          data: @[byte 9])))
      expect TimeoutError:
        discard conn.recv(1, timeout = 100) # nothing arrives

      # FIN: tunnel dropped, service socket sees EOF
      s.tox.onLosslessPacket(7'u32, encodeFrame(
        Frame(friendnumber: 7, magic: protocolMagic,
          packetType: packetTypeTcpFin, connId: ack.connId)))
      check s.tunnels.len == 0
      check conn.recv(1) == ""

      conn.close()
      service.close()
    run()

  test "unreachable target is denied":
    proc run() =
      var sent: seq[seq[byte]] = @[]
      let s = newTunnelServer(stateDir, "sekrit")
      s.sendHook = proc (srv: TunnelServer; friendnumber: uint32;
          packet: seq[byte]): bool =
        sent.add(packet)
        true

      # port 1 on localhost: nothing listens there, connect is refused
      s.tox.onLosslessPacket(7'u32, encodeFrame(
        makeRequestTunnel(7'u32, "127.0.0.1", 1'u16, 0xdeadbeef'u32)))
      check s.tunnels.len == 1 # pending until the refused connect settles
      s.poll()
      check sent.len == 1
      let deny = decodeFrame(7'u32, sent[0])
      check deny.packetType == packetTypeDenyTunnel
      check deny.data == @[byte 0xde, 0xad, 0xbe, 0xef]
      check s.tunnels.len == 0
    run()
