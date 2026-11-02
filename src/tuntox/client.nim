## The tuntox client, translated from client.c: a persistent identity
## that befriends a server by Tox ID (the friend request carries the
## shared secret), local listeners whose accepted connections become
## tunnels via the REQUESTTUNNEL/ACKTUNNEL handshake, and a TCP relay
## between the local peer and the tox friend. Like the server, everything
## is driven by `poll` — no threads, no globals.

import std/[net, nativesockets, os, random, selectors, tables, times]
import bootstrap, protocol, tox, tunnels

const invitationRetrySeconds = 45
  ## C: re-send the friend request if it was not accepted in 45s

type
  SendHook* = proc (c: TunnelClient; friendnumber: uint32;
    packet: seq[byte]): bool {.gcsafe.}
    ## How frames leave the client. Default: tox lossless packets.
    ## Tests swap this out to capture the wire.

  TunnelClientObj* = object
    tox*: ToxInstance
    remoteToxId*: string
    sharedSecret*: string
    stateDir*: string
    friendnumber*: uint32
    forwards*: seq[LocalForward]
    tunnels*: TunnelRegistry
    sendHook*: SendHook
    selector: Selector[uint32]  ## fd -> forward id (listeners) or tunnel conn id
    rng: Rand                   ## random forward ids
    friendConnected*: bool
    reconnectNeeded: bool        ## set by the friend-status callback, acted on in poll
    invitationSent: Time
  TunnelClient* = ref TunnelClientObj

proc `=destroy`(c: TunnelClientObj) =
  if c.selector != nil:
    for f in c.forwards:
      f.bindSock.close()
      # an acked forward's socket is owned by its tunnel and closed below
      if not f.isAcked and f.acceptSock != nil:
        f.acceptSock.close()
    for tun in values(c.tunnels.tunnels):
      tun.sock.close()
    # destructors must not raise, so a failing selector teardown is
    # swallowed here — there is no caller left to report it to
    try:
      c.selector.close()
    except IOSelectorsException:
      discard

proc sendFrame(c: TunnelClient; f: Frame): bool =
  var f = f
  f.magic = protocolMagic # everything we emit speaks protocol v2
  c.sendHook(c, f.friendnumber, encodeFrame(f))

proc saveState*(c: TunnelClient) =
  ## Persist the tox identity — atomic via tmp + rename.
  let path = c.stateDir / "tox_save"
  let tmp = path & ".tmp"
  writeFile(tmp, cast[string](c.tox.savedata()))
  moveFile(tmp, path)

proc bootstrap*(c: TunnelClient; host: string; port: uint16;
    keyHex: string) =
  ## An extra bootstrap node beyond the static list — tests point both
  ## ends at a local DHT node for a hermetic loopback network.
  c.tox.bootstrap(host, port, keyHex)

proc toxId*(c: TunnelClient): string =
  ## The client's own Tox ID (76 hex chars).
  c.tox.address

proc freshForwardId(c: TunnelClient): uint32 =
  while true:
    result = c.rng.rand(uint32)
    if findForwardById(c.forwards, result) == nil:
      break

proc forwardByBindFd(c: TunnelClient; fd: int): LocalForward =
  for f in c.forwards:
    if f.bindSock.getFd().int == fd:
      return f

proc closeTunnel(c: TunnelClient; tun: Tunnel) =
  ## C: client_close_tunnel. The forward keeps pointing at the tunnel's
  ## socket, so closing also resets it for the next local connection —
  ## C loses that link and never clears is_acked, which would wedge the
  ## forward after its first tunnel.
  let forward = findForwardBySock(c.forwards, tun.sock)
  c.selector.unregister(tun.sock.getFd())
  tun.sock.close()
  c.tunnels.remove(tun.connId)
  if forward != nil:
    forward.acceptSock = nil
    forward.isAcked = false

proc closeAllTunnels(c: TunnelClient) =
  var ids: seq[uint16] = @[]
  for connId in c.tunnels.tunnels.keys:
    ids.add(connId)
  for connId in ids:
    c.closeTunnel(c.tunnels.get(connId))

proc resetPendingForwards(c: TunnelClient) =
  ## Drop accepted sockets that never got an ACK (C: the accept_sockfd
  ## reset in client_close_all_connections).
  for f in c.forwards:
    if not f.isAcked and f.acceptSock != nil:
      f.acceptSock.close()
      f.acceptSock = nil

func requestMessage(c: TunnelClient): string =
  ## toxcore refuses zero-length friend-request messages, so a secretless
  ## pairing sends a lone NUL — the server strips trailing NULs before
  ## comparing, so both sides still see the empty secret.
  if c.sharedSecret.len > 0: c.sharedSecret else: "\0"

proc resendFriendRequest(c: TunnelClient) =
  ## C: CLIENT_STATE_CONNECTION_LOST and the 45s invitation retry — drop
  ## the dead friend entry and send a fresh request. Failures leave the
  ## timer reset, so the next poll tries again.
  c.closeAllTunnels()
  c.resetPendingForwards()
  try:
    c.tox.friendDelete(c.friendnumber)
  except ToxError:
    discard
  try:
    c.friendnumber = c.tox.friendAdd(c.remoteToxId, requestMessage(c))
  except ToxError:
    discard
  c.invitationSent = getTime()
  saveState(c)

proc handleAckTunnel*(c: TunnelClient; f: Frame) =
  ## C: handle_acktunnel_frame — bind the pending accepted socket to the
  ## tunnel id the server assigned. The forward keeps its acceptSock (now
  ## owned by the tunnel) so closeTunnel can find it back.
  if f.data.len < 4:
    return
  let forward = findPendingForwardById(c.forwards, be32(f.data, 0))
  if forward == nil:
    return
  forward.isAcked = true
  let tun = Tunnel(connId: f.connId, sock: forward.acceptSock,
    friendnumber: f.friendnumber, forwardId: forward.forwardId)
  c.tunnels.add(tun)
  c.selector.registerHandle(tun.sock.getFd(), {Read},
    uint32(tun.connId))

proc handleDenyTunnel*(c: TunnelClient; f: Frame) =
  ## The server could not connect to the forwarded host: close the local
  ## peer and let the listener accept again. (DENYTUNNEL is our own
  ## extension — the C client never receives one.)
  if f.data.len < 4:
    return
  let forward = findPendingForwardById(c.forwards, be32(f.data, 0))
  if forward == nil:
    return
  forward.acceptSock.close()
  forward.acceptSock = nil

proc handleServerTcpFrame*(c: TunnelClient; f: Frame) =
  ## C: handle_server_tcp_frame — write the payload to the local peer.
  let tun = c.tunnels.get(f.connId)
  if tun == nil or tun.friendnumber != f.friendnumber:
    return
  if f.data.len == 0:
    return
  # std/net's send raises on partial writes, so a full write or the
  # tunnel closes — same outcome as C's send() error path
  try:
    tun.sock.send(cast[string](f.data))
  except OSError:
    discard c.sendFrame(Frame(friendnumber: tun.friendnumber,
      packetType: packetTypeTcpFin, connId: tun.connId))
    c.closeTunnel(tun)

proc handleServerTcpFinFrame*(c: TunnelClient; f: Frame) =
  ## C: handle_server_tcp_fin_frame — the server closed the tunnel.
  let tun = c.tunnels.get(f.connId)
  if tun == nil or tun.friendnumber != f.friendnumber:
    return
  c.closeTunnel(tun)

proc dispatch(c: TunnelClient; friendnumber: uint32; data: seq[byte]) =
  ## C: parse_lossless_packet + handle_frame.
  try:
    let f = decodeFrame(friendnumber, data)
    case f.packetType
    of packetTypeAckTunnel: c.handleAckTunnel(f)
    of packetTypeDenyTunnel: c.handleDenyTunnel(f)
    of packetTypeTcp: c.handleServerTcpFrame(f)
    of packetTypeTcpFin: c.handleServerTcpFinFrame(f)
    else: discard # unknown packet types are ignored, like C's default case
  except ValueError:
    discard # malformed frame: drop it, keep serving the friend

proc addForward*(c: TunnelClient; localPort: int; remoteHost: string;
    remotePort: uint16): LocalForward =
  ## Forward `localPort` on this machine to `remoteHost:remotePort` on the
  ## server (C: -L local_port:remote_host:remote_port). The listener binds
  ## loopback only — unlike C's wildcard bind, the tunnel is not exposed to
  ## the network. A tunnel is requested once a local connection is accepted.
  let bindSock = newSocket(buffered = false)
  bindSock.getFd().setBlocking(false)
  bindSock.setSockOpt(OptReuseAddr, true)
  bindSock.bindAddr(Port(localPort), "127.0.0.1")
  bindSock.listen()
  result = LocalForward(
    localPort: localPort,
    remoteHost: remoteHost,
    remotePort: remotePort,
    bindSock: bindSock,
    forwardId: c.freshForwardId(),
    created: getTime(),
  )
  c.selector.registerHandle(bindSock.getFd(), {Read}, result.forwardId)
  c.forwards.add(result)

proc poll*(c: TunnelClient) =
  ## One iteration: tox_iterate, then every ready local socket. Call this
  ## every `iterationInterval` milliseconds from the host's event loop.
  c.tox.iterate()
  if c.reconnectNeeded or (not c.friendConnected and
      getTime() - c.invitationSent >
        initDuration(seconds = invitationRetrySeconds)):
    c.reconnectNeeded = false
    c.resendFriendRequest()
  # winsock's select() rejects an empty fd set (WSAEINVAL): nothing to wait on
  let ready = if c.selector.isEmpty: newSeq[ReadyKey]() else: c.selector.select(0)
  for ev in ready:
    let f = c.forwardByBindFd(ev.fd)
    if f != nil:
      # local listener ready — accept one connection and request a tunnel
      # (C: one pending tunnel per forward at a time). The listener binds
      # before the friend is connected, so a peer that connects early sits
      # in the kernel backlog until the connection is up — accepting now
      # would send REQUESTTUNNEL into the void and wedge the forward.
      if f.acceptSock == nil and c.friendConnected:
        var peer: Socket
        f.bindSock.accept(peer)
        peer.getFd().setBlocking(false)
        f.acceptSock = peer
        discard c.sendFrame(makeRequestTunnel(c.friendnumber, f.remoteHost,
          f.remotePort, f.forwardId))
      continue
    let tun = c.tunnels.get(uint16(c.selector.getData(ev.fd)))
    if tun == nil:
      continue
    if Read in ev.events:
      let data = tun.sock.recv(maxDataLength)
      if data.len == 0:
        # local peer closed: tell the server (C sends TCP_FIN) and drop
        discard c.sendFrame(Frame(friendnumber: tun.friendnumber,
          packetType: packetTypeTcpFin, connId: tun.connId))
        c.closeTunnel(tun)
      else:
        discard c.sendFrame(Frame(friendnumber: tun.friendnumber,
          packetType: packetTypeTcp, connId: tun.connId,
          data: cast[seq[byte]](data)))

proc iterationInterval*(c: TunnelClient): int =
  ## Milliseconds the caller may sleep before the next `poll`.
  c.tox.iterationInterval()

proc newTunnelClient*(stateDir, sharedSecret, remoteToxId: string): TunnelClient =
  ## Client with a persistent identity: `<stateDir>/tox_save` is loaded if
  ## present (same Tox ID across restarts). Befriends the server at
  ## `remoteToxId`, carrying `sharedSecret` as the friend-request message —
  ## the server only accepts requests that present its secret.
  if not dirExists(stateDir):
    createDir(stateDir)
  let savePath = stateDir / "tox_save"
  var savedata: seq[byte] = @[]
  if fileExists(savePath):
    savedata = cast[seq[byte]](readFile(savePath))

  # `result` cannot be captured by closures, so wire up a local first
  var c = TunnelClient(
    tox: newTox(savedata),
    remoteToxId: remoteToxId,
    sharedSecret: sharedSecret,
    stateDir: stateDir,
    tunnels: newTunnelRegistry(),
    selector: newSelector[uint32](),
    rng: initRand(),
    invitationSent: getTime(),
  )
  c.sendHook = proc (cl: TunnelClient; friendnumber: uint32;
      packet: seq[byte]): bool =
    cl.tox.sendLosslessPacket(friendnumber, packet)
  # befriend the server; on a restart the friend is already in our list,
  # so the request fails with ALREADY_SENT and we look the number up
  try:
    c.friendnumber = c.tox.friendAdd(remoteToxId, requestMessage(c))
  except ToxError:
    c.friendnumber = c.tox.friendByPublicKey(remoteToxId[0 ..< 64])
  c.tox.onFriendConnection = proc (friendNumber: uint32;
      connected: bool) =
    if friendNumber == c.friendnumber:
      c.friendConnected = connected
      if not connected:
        c.reconnectNeeded = true
  c.tox.onLosslessPacket = proc (friendnumber: uint32;
      data: seq[byte]) =
    c.dispatch(friendnumber, data)
  bootstrapInto(c.tox)
  saveState(c)
  result = c
