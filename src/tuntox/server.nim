## The tuntox server, translated from main.c's server half: friend
## requests gated by a shared secret, tunnel requests answered with
## ACK/DENY, and a TCP relay between the tox friend and the forwarded
## host. Everything is driven by `poll` — no threads, no globals — so a
## host editor can call it from its own tick.

import std/[net, nativesockets, os, random, selectors, strutils, tables]
when defined(windows):
  from std/winlean import WSAEWOULDBLOCK
  const EINPROGRESS = WSAEWOULDBLOCK  # winsock reports a pending connect so
  const EWOULDBLOCK = WSAEWOULDBLOCK
else:
  from std/posix import EINPROGRESS, EWOULDBLOCK
import bootstrap, protocol, tox, tunnels

type
  SendHook* = proc (s: TunnelServer; friendnumber: uint32;
    packet: seq[byte]): bool {.gcsafe.}
    ## How frames leave the server. Default: tox lossless packets.
    ## Tests swap this out to capture the wire.

  TunnelServerObj* = object
    tox*: ToxInstance
    tunnels*: TunnelRegistry
    sharedSecret*: string
    stateDir*: string
    sendHook*: SendHook
    selector: Selector[uint16]  ## fd -> tunnel conn id
    rng: Rand                  ## random tunnel ids (C: get_random_tunnel_id)
  TunnelServer* = ref TunnelServerObj

proc `=destroy`(s: TunnelServerObj) =
  if s.selector != nil:
    for tun in values(s.tunnels.tunnels):
      tun.sock.close()
    # destructors must not raise, so a failing selector teardown is
    # swallowed here — there is no caller left to report it to
    try:
      s.selector.close()
    except IOSelectorsException:
      discard

func forwardIdData(id: uint32): seq[byte] =
  @[byte(id shr 24), byte(id shr 16), byte(id shr 8), byte(id)]

proc sendFrame(s: TunnelServer; f: Frame): bool =
  var f = f
  f.magic = protocolMagic # everything we emit speaks protocol v2
  s.sendHook(s, f.friendnumber, encodeFrame(f))

proc saveState*(s: TunnelServer) =
  ## Persist the tox identity (C: write_save) — atomic via tmp + rename.
  let path = s.stateDir / "tox_save"
  let tmp = path & ".tmp"
  writeFile(tmp, cast[string](s.tox.savedata()))
  moveFile(tmp, path)

proc bootstrap*(s: TunnelServer; host: string; port: uint16;
    keyHex: string) =
  ## An extra bootstrap node beyond the static list — tests point both
  ## ends at a local DHT node for a hermetic loopback network.
  s.tox.bootstrap(host, port, keyHex)

proc toxId*(s: TunnelServer): string =
  ## The server's Tox ID (76 hex chars) — share this with clients.
  s.tox.address

proc acceptFriend*(s: TunnelServer; publicKeyHex, message: string): bool =
  ## Friend requests must carry the shared secret (C: accept_friend_request
  ## strncmp's the message against it); anything else is rejected.
  if message.strip(chars = {'\0'}) != s.sharedSecret:
    return false
  try:
    discard s.tox.friendAddNoRequest(publicKeyHex)
    result = true
  except ToxError:
    result = false

proc dropTunnel(s: TunnelServer; tun: Tunnel) =
  s.selector.unregister(tun.sock.getFd())
  tun.sock.close()
  s.tunnels.remove(tun.connId)

proc freshConnId(s: TunnelServer): uint16 =
  while true:
    result = uint16(s.rng.rand(65535))
    if not s.tunnels.contains(result):
      break

proc handleRequestTunnel*(s: TunnelServer; f: Frame) =
  ## C: handle_request_tunnel_frame. The connect() is non-blocking, so the
  ## ACK/DENY goes out from `poll` once the socket's fate is known.
  let req = parseRequestTunnel(f)
  let sock = newSocket(buffered = false)
  sock.getFd().setBlocking(false)
  try:
    sock.connect(req.host, req.port.Port)
  except OSError as e:
    if e.errorCode.int32 != EINPROGRESS and e.errorCode.int32 != EWOULDBLOCK:
      # resolution or immediate failure — deny right away
      sock.close()
      discard s.sendFrame(Frame(friendnumber: f.friendnumber,
        packetType: packetTypeDenyTunnel, connId: 0,
        data: forwardIdData(req.forwardId)))
      return
  let connId = s.freshConnId()
  s.tunnels.add(Tunnel(connId: connId, sock: sock,
    friendnumber: f.friendnumber, remoteHost: req.host,
    remotePort: req.port, forwardId: req.forwardId, ackPending: true))
  s.selector.registerHandle(sock.getFd(), {Read, Write}, connId)

proc handleTcpFrame*(s: TunnelServer; f: Frame) =
  ## C: handle_client_tcp_frame — write the payload to the forwarded host.
  let tun = s.tunnels.get(f.connId)
  if tun == nil:
    return # unknown tunnel id
  if tun.friendnumber != f.friendnumber:
    return # not this tunnel's owner
  if f.data.len > 0:
    tun.sock.send(cast[string](f.data))

proc handleTcpFinFrame*(s: TunnelServer; f: Frame) =
  ## C: handle_client_tcp_fin_frame — close and drop the tunnel.
  let tun = s.tunnels.get(f.connId)
  if tun == nil or tun.friendnumber != f.friendnumber:
    return
  s.dropTunnel(tun)

proc dispatch(s: TunnelServer; friendnumber: uint32; data: seq[byte]) =
  ## C: parse_lossless_packet + handle_frame.
  try:
    let f = decodeFrame(friendnumber, data)
    case f.packetType
    of packetTypeRequestTunnel: s.handleRequestTunnel(f)
    of packetTypeTcp: s.handleTcpFrame(f)
    of packetTypeTcpFin: s.handleTcpFinFrame(f)
    else: discard # unknown packet types are ignored, like C's default case
  except ValueError:
    discard # malformed frame: drop it, keep serving the friend

proc poll*(s: TunnelServer) =
  ## One iteration: tox_iterate, then every ready tunnel socket. Call this
  ## every `iterationInterval` milliseconds from the host's event loop.
  s.tox.iterate()
  # winsock's select() rejects an empty fd set (WSAEINVAL): nothing to wait on
  let ready = if s.selector.isEmpty: newSeq[ReadyKey]() else: s.selector.select(0)
  for ev in ready:
    let tun = s.tunnels.get(s.selector.getData(ev.fd))
    if tun == nil:
      continue
    if tun.ackPending and Write in ev.events:
      # connect() settled: SO_ERROR tells ACK from DENY
      if getSockOptInt(tun.sock.getFd(), SOL_SOCKET, SO_ERROR) == 0:
        tun.ackPending = false
        tun.sock.getFd().setBlocking(true)
        s.selector.updateHandle(tun.sock.getFd(), {Read})
        discard s.sendFrame(Frame(friendnumber: tun.friendnumber,
          packetType: packetTypeAckTunnel, connId: tun.connId,
          data: forwardIdData(tun.forwardId)))
      else:
        discard s.sendFrame(Frame(friendnumber: tun.friendnumber,
          packetType: packetTypeDenyTunnel, connId: 0,
          data: forwardIdData(tun.forwardId)))
        s.dropTunnel(tun)
      continue
    if Read in ev.events:
      let data = tun.sock.recv(maxDataLength)
      if data.len == 0:
        # forwarded host closed: tell the client (C sends TCP_FIN) and drop
        discard s.sendFrame(Frame(friendnumber: tun.friendnumber,
          packetType: packetTypeTcpFin, connId: tun.connId))
        s.dropTunnel(tun)
      else:
        discard s.sendFrame(Frame(friendnumber: tun.friendnumber,
          packetType: packetTypeTcp, connId: tun.connId,
          data: cast[seq[byte]](data)))

proc iterationInterval*(s: TunnelServer): int =
  ## Milliseconds the caller may sleep before the next `poll`.
  s.tox.iterationInterval()

proc newTunnelServer*(stateDir, sharedSecret: string): TunnelServer =
  ## Server with a persistent identity: `<stateDir>/tox_save` is loaded if
  ## present (same Tox ID across restarts) and rewritten whenever the
  ## friend list changes.
  if not dirExists(stateDir):
    createDir(stateDir)
  let savePath = stateDir / "tox_save"
  var savedata: seq[byte] = @[]
  if fileExists(savePath):
    savedata = cast[seq[byte]](readFile(savePath))

  # `result` cannot be captured by closures, so wire up a local first
  var s = TunnelServer(
    tox: newTox(savedata),
    tunnels: newTunnelRegistry(),
    sharedSecret: sharedSecret,
    stateDir: stateDir,
    selector: newSelector[uint16](),
    rng: initRand(),
  )
  s.sendHook = proc (srv: TunnelServer; friendnumber: uint32;
      packet: seq[byte]): bool =
    srv.tox.sendLosslessPacket(friendnumber, packet)
  s.tox.onFriendRequest = proc (publicKey, message: string) =
    if s.acceptFriend(publicKey, message):
      saveState(s)
  s.tox.onLosslessPacket = proc (friendnumber: uint32;
      data: seq[byte]) =
    s.dispatch(friendnumber, data)
  bootstrapInto(s.tox)
  saveState(s)
  result = s
