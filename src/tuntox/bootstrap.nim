## Static DHT bootstrap node list (C: tox_bootstrap.h, generated from
## https://nodes.tox.chat on 2025-08-27). A handful of live nodes is
## enough to reach the DHT; one dead entry must not sink the rest.

import tox

type BootstrapNode* = tuple[host: string, port: uint16, keyHex: string]

const bootstrapNodesLen* = 10

const bootstrapNodes*: array[bootstrapNodesLen, BootstrapNode] = [
  ("144.217.167.73", 33445'u16,
   "7E5668E0EE09E19F320AD47902419331FFEE147BB3606769CFBE921A2A2FD34C"),
  ("24.87.200.52", 33445'u16,
   "10C00EB250C3233E343E2AEBA07115A5C28920E9C8D29492F6D00B29049EDC7E"),
  ("134.122.80.232", 33445'u16,
   "82EF82BA33445A1F91A7DB27189ECFC0C013E06E3DA71F588ED692BED625EC23"),
  ("45.32.184.23", 33445'u16,
   "81C916A3605724106C2E7487DC72FF2F9EB662EB34C85C0C692D8312B442635C"),
  ("49.12.229.145", 33445'u16,
   "B3E5FA80DC8EBD1149AD2AB35ED8B85BD546DEDE261CA593234C619249419506"),
  ("217.156.65.161", 33445'u16,
   "836D1DA2BE12FE0E669334E437BE3FB02806F1528C2B2782113E0910C7711409"),
  ("188.225.9.167", 33445'u16,
   "1911341A83E02503AB1FD6561BD64AF3A9D6C3F12B5FBB656976B2E678644A67"),
  ("3.0.24.15", 33445'u16,
   "E20ABCF38CDBFFD7D04B29C956B33F7B27A3BB7AF0618101617B036E4AEA402D"),
  ("104.225.141.59", 43334'u16,
   "933BA20B2E258B4C0D475B6DECE90C7E827FE83EFA9655414E7841251B19A72C"),
  ("172.105.109.31", 33445'u16,
   "D46E97CF995DC1820B92B7D899E152A217D36ABE22730FEA4B6BF1BFC06C617C"),
]

proc bootstrapInto*(t: ToxInstance) =
  ## Offer every node to toxcore; tox resolves and retries them in the
  ## background while `iterate` is being called.
  for n in bootstrapNodes:
    try:
      t.bootstrap(n.host, n.port, n.keyHex)
    except ToxError:
      discard # one unreachable node must not abort the rest
