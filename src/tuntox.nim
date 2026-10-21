## tuntox — TCP tunnels over the Tox network, as an embeddable Nim
## library (gjedeer/tuntox translated; no CLI, no globals, no threads).
##
## Server — accepts tunnels from friends who know the shared secret:
##
##     let server = newTunnelServer("/var/lib/myapp", "hunter2")
##     writeFile("/srv/tox.id", server.toxId())  # share this with clients
##     while running:
##       server.poll()
##       sleep(server.iterationInterval())
##
## Client — forward a local port through a server:
##
##     let client = newTunnelClient(getTempDir() / "tox", "hunter2",
##                                  serverToxId)
##     discard client.addForward(6543, "127.0.0.1", 6543)
##     while running:
##       client.poll()
##       sleep(client.iterationInterval())
##
## Both sides persist their Tox identity in `<stateDir>/tox_save`, so the
## Tox ID (and the friend list) survive restarts.

import tuntox/[client, server, tunnels]

export client.TunnelClient, client.newTunnelClient, client.addForward,
  client.poll, client.iterationInterval, client.toxId, client.saveState,
  client.bootstrap
export server.TunnelServer, server.newTunnelServer, server.toxId,
  server.poll, server.iterationInterval, server.acceptFriend,
  server.saveState, server.bootstrap
export tunnels.LocalForward
