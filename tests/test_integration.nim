## End-to-end: a real TunnelServer and a real TunnelClient talking over
## a loopback Tox network. A local DHT_bootstrap node (built alongside
## toxcore) is the rendezvous, and a TCP echo server stands in for the
## forwarded service — no internet required. Skipped when the
## DHT_bootstrap binary is not installed or UDP 33445 is taken.

import std/[net, nativesockets, os, osproc, strutils, times, unittest]
import std/typedthreads
import tuntox/[client, server, tunnels]

const dhtPort = 33445
const sharedSecret = "sekrit"
const deadlineSeconds = 60

let dhtBin = getHomeDir() / ".local/bin/DHT_bootstrap"
let stateA = getTempDir() / "nim_tuntox_integration_server"
let stateB = getTempDir() / "nim_tuntox_integration_client"

proc udpPortFree(port: int): bool =
  let fd = createNativeSocket(Domain.AF_INET, SockType.SOCK_DGRAM,
    Protocol.IPPROTO_UDP)
  if fd == osInvalidSocket:
    return false
  var a: Sockaddr_in
  a.sin_family = uint16(toInt(Domain.AF_INET))
  a.sin_port = nativesockets.htons(uint16(port))
  try:
    if nativesockets.bindAddr(fd, cast[ptr SockAddr](addr a),
        SockLen(sizeof(a))) == 0:
      result = true
  except OSError:
    result = false
  finally:
    fd.close()

proc freeTcpPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = s.getLocalAddr()[1].int
  s.close()

proc echoWorker(port: int) {.thread.} =
  # unbuffered, like every socket in the library: recv returns whatever
  # is available instead of waiting for the full requested size
  var listener = newSocket(buffered = false)
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port), "127.0.0.1")
  listener.listen()
  while true:
    var peer: Socket
    listener.accept(peer)
    while true:
      let data = peer.recv(4096)
      if data.len == 0:
        break
      peer.send(data)
    peer.close()

suite "end-to-end over a loopback tox network":
  test "echo through a tunnel between a real server and client":
    if not fileExists(dhtBin) or not udpPortFree(dhtPort):
      skip() # no local DHT node available on this machine
    else:
      proc run() =
        removeDir(stateA)
        removeDir(stateB)

        # the rendezvous: a local DHT node both tox instances bootstrap to
        let dhtDir = getTempDir() /
          ("nim_tuntox_dht_" & $getCurrentProcessId())
        createDir(dhtDir)
        let dht = startProcess(dhtBin, workingDir = dhtDir,
          args = ["--ipv4"])
        defer: # never leave a DHT node behind, whatever happens below
          dht.kill()
          dht.close()
        var key = ""
        for i in 1 .. 100: # it writes PUBLIC_ID.txt once it is listening
          if fileExists(dhtDir / "PUBLIC_ID.txt"):
            key = readFile(dhtDir / "PUBLIC_ID.txt").strip()
            break
          sleep(100)
        if key.len != 64 or udpPortFree(dhtPort):
          checkpoint "DHT_bootstrap never came up on UDP " & $dhtPort
          check false
          return

        # the forwarded service: a TCP echo server in a helper thread
        let echoPort = freeTcpPort()
        var echoThread: Thread[int]
        createThread(echoThread, echoWorker, echoPort)

        let server = newTunnelServer(stateA, sharedSecret)
        let client = newTunnelClient(stateB, sharedSecret,
          server.toxId())
        server.bootstrap("127.0.0.1", dhtPort.uint16, key)
        client.bootstrap("127.0.0.1", dhtPort.uint16, key)
        let localPort = freeTcpPort()
        discard client.addForward(localPort, "127.0.0.1",
          echoPort.uint16)

        # a local peer connects through the forward right away — before the
        # friend request is even accepted — and queues its data, the way a
        # collab client joins as soon as the local listener is up
        let peer = newSocket()
        peer.connect("127.0.0.1", Port(localPort))
        peer.getFd().setBlocking(false)
        let message = "ping through the tox tunnel"
        peer.send(message)

        # drive both sides until the friend request (carrying the shared
        # secret) is accepted, the connection is up, and the echo returns
        let deadline = getTime() + initDuration(seconds = deadlineSeconds)
        var echoed = ""
        while echoed.len < message.len:
          if getTime() >= deadline:
            check false # echo never came back
            return
          server.poll()
          client.poll()
          try:
            let chunk = peer.recv(4096)
            if chunk.len > 0:
              echoed.add(chunk)
          except OSError: # EWOULDBLOCK on the non-blocking peer
            discard
          sleep(5)
        check echoed == message

        # the local peer hangs up: FIN both ways, both tunnels gone
        peer.close()
        while client.tunnels.len > 0 or server.tunnels.len > 0:
          if getTime() >= deadline:
            check false # tunnels never drained
            return
          server.poll()
          client.poll()
          sleep(5)
        check client.tunnels.len == 0
        check server.tunnels.len == 0

      run()
