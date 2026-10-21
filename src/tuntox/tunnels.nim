## Tunnel bookkeeping for both sides of the relay.
##
## Server side: `TunnelRegistry` maps conn ids to live tunnels (the C
## code uses uthash for this). Client side: `LocalForward` entries track
## a local listener through the request/ack handshake (client.c's
## local_port_forward list).

import std/[net, tables, times]

type
  Tunnel* = ref object
    connId*: uint16
    sock*: Socket              ## non-blocking connection to the forwarded host
    friendnumber*: uint32      ## friend on the other end of the tunnel
    remoteHost*: string
    remotePort*: uint16
    forwardId*: uint32     ## client-side id, echoed back in the ACKTUNNEL reply
    ackPending*: bool      ## server side: connect() finished, ACK not yet sent

  TunnelRegistry* = ref object
    tunnels*: Table[uint16, Tunnel]

  LocalForward* = ref object
    localPort*: int
    remoteHost*: string
    remotePort*: uint16
    bindSock*: Socket           ## local listener; accept() on it
    acceptSock*: Socket         ## accepted connection pending the ACK
    forwardId*: uint32          ## matches the ACKTUNNEL reply
    isAcked*: bool
    created*: Time              ## for ack timeouts

proc newTunnelRegistry*(): TunnelRegistry =
  TunnelRegistry(tunnels: initTable[uint16, Tunnel]())

proc add*(r: TunnelRegistry; t: Tunnel) =
  r.tunnels[t.connId] = t

proc remove*(r: TunnelRegistry; connId: uint16) =
  r.tunnels.del(connId)

proc get*(r: TunnelRegistry; connId: uint16): Tunnel =
  r.tunnels.getOrDefault(connId)

proc contains*(r: TunnelRegistry; connId: uint16): bool =
  connId in r.tunnels

proc len*(r: TunnelRegistry): int =
  r.tunnels.len

proc findForwardById*(forwards: seq[LocalForward];
    forwardId: uint32): LocalForward =
  ## The forward with this id, or nil (C: find_forward_by_id).
  for f in forwards:
    if f.forwardId == forwardId:
      return f

proc findPendingForwardById*(forwards: seq[LocalForward];
    forwardId: uint32): LocalForward =
  ## The forward with this id if it is still waiting for its ACKTUNNEL
  ## (C: find_pending_forward_by_id).
  let f = findForwardById(forwards, forwardId)
  if f != nil and not f.isAcked:
    result = f

proc findForwardBySock*(forwards: seq[LocalForward];
    sock: Socket): LocalForward =
  ## The forward whose accepted socket is this one (C: find_forward_by_sock).
  for f in forwards:
    if f.acceptSock == sock:
      return f
