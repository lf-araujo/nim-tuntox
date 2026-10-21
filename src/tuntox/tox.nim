## tox.nim — curated, GC-managed API over the c2nim binding (tox_raw.nim).
##
## Only what the tunnel library needs: identity persistence, bootstrap,
## iteration, and the four callbacks (friend request / connection status /
## self connection / lossless packets). Nim owns the lifetime: the last
## reference drop runs tox_kill via the destructor — no manual free.

import std/strutils
import tox_raw

export tox_raw.TOX_ADDRESS_SIZE, tox_raw.TOX_PUBLIC_KEY_SIZE

type
  ToxError* = object of CatchableError

  ToxObj = object
    raw: ptr Tox
    ## Callbacks are plain Nim closures; the cdecl trampolines below
    ## recover the instance from user_data and forward to them.
    onFriendRequest*: proc (publicKey: string; message: string) {.gcsafe.}
    onFriendConnection*: proc (friendNumber: uint32; connected: bool) {.gcsafe.}
    onSelfConnection*: proc (connected: bool) {.gcsafe.}
    onLosslessPacket*: proc (friendNumber: uint32; data: seq[byte]) {.gcsafe.}
  ToxInstance* = ref ToxObj

proc `=destroy`(t: ToxObj) =
  if t.raw != nil:
    tox_kill(t.raw)

func hex(b: openArray[uint8]): string =
  const digits = "0123456789ABCDEF"
  result = newString(b.len * 2)
  for i, c in b:
    result[i * 2] = digits[c shr 4]
    result[i * 2 + 1] = digits[c and 0xf]

proc checkErr(ok: bool; e: var int32; what: string) =
  if not ok:
    raise newException(ToxError, what & " failed: error " & $e)

proc newTox*(savedata: seq[byte] = @[]): ToxInstance =
  ## Create a Tox instance, optionally restoring it from `savedata`
  ## (as previously returned by the `savedata` proc).
  var optErr: Tox_Err_Options_New
  let opts = tox_options_new(addr optErr)
  if opts == nil:
    raise newException(ToxError, "tox_options_new failed: " & $optErr)
  defer: tox_options_free(opts)
  tox_options_default(opts)
  var err: Tox_Err_New
  var raw: ptr Tox
  if savedata.len > 0:
    tox_options_set_savedata_type(opts, TOX_SAVEDATA_TYPE_TOX_SAVE)
    tox_options_set_savedata_data(opts, unsafeAddr savedata[0],
                                  csize_t savedata.len)
    raw = tox_new(opts, addr err)
  else:
    raw = tox_new(opts, addr err)
  if raw == nil:
    raise newException(ToxError, "tox_new failed: " & $err)
  result = ToxInstance(raw: raw)

  tox_callback_friend_request(raw,
    proc (t: ptr Tox; pk: array[TOX_PUBLIC_KEY_SIZE, uint8];
          msg: ptr uint8; len: csize_t; ud: pointer) {.cdecl.} =
      let self = cast[ToxInstance](ud)
      if self != nil and self.onFriendRequest != nil:
        var m = newString(len)
        if len > 0: copyMem(addr m[0], msg, len)
        self.onFriendRequest(hex(pk), m)
  )
  tox_callback_friend_connection_status(raw,
    proc (t: ptr Tox; friend: Tox_Friend_Number; status: Tox_Connection;
          ud: pointer) {.cdecl.} =
      let self = cast[ToxInstance](ud)
      if self != nil and self.onFriendConnection != nil:
        self.onFriendConnection(friend.uint32, status != TOX_CONNECTION_NONE)
  )
  tox_callback_self_connection_status(raw,
    proc (t: ptr Tox; status: Tox_Connection; ud: pointer) {.cdecl.} =
      let self = cast[ToxInstance](ud)
      if self != nil and self.onSelfConnection != nil:
        self.onSelfConnection(status != TOX_CONNECTION_NONE)
  )
  tox_callback_friend_lossless_packet(raw,
    proc (t: ptr Tox; friend: Tox_Friend_Number; data: ptr uint8;
          len: csize_t; ud: pointer) {.cdecl.} =
      let self = cast[ToxInstance](ud)
      if self != nil and self.onLosslessPacket != nil:
        var buf = newSeq[byte](len)
        if len > 0: copyMem(addr buf[0], data, len)
        self.onLosslessPacket(friend.uint32, buf)
  )

proc address*(t: ToxInstance): string =
  ## The Tox ID (address) as 76 hex chars.
  var buf: array[TOX_ADDRESS_SIZE, uint8]
  tox_self_get_address(t.raw, buf)
  hex(buf)

proc savedata*(t: ToxInstance): seq[byte] =
  ## The state blob to persist for identity continuity.
  let n = tox_get_savedata_size(t.raw)
  result = newSeq[byte](n)
  if n > 0: tox_get_savedata(t.raw, addr result[0])

proc bootstrap*(t: ToxInstance; host: string; port: uint16; keyHex: string) =
  ## Add a DHT bootstrap node (keyHex: 64 hex chars).
  var err: Tox_Err_Bootstrap
  var key: array[TOX_PUBLIC_KEY_SIZE, uint8]
  if keyHex.len != TOX_PUBLIC_KEY_SIZE * 2:
    raise newException(ToxError, "bad bootstrap key length")
  for i in 0 ..< TOX_PUBLIC_KEY_SIZE:
    key[i] = uint8(parseHexInt(keyHex[i * 2 ..< i * 2 + 2]))
  if not tox_bootstrap(t.raw, host, port, key, addr err):
    raise newException(ToxError, "bootstrap failed: " & $err)

proc iterate*(t: ToxInstance) =
  ## One iteration; callbacks fire synchronously with `t` as user_data.
  tox_iterate(t.raw, cast[pointer](t))

proc iterationInterval*(t: ToxInstance): int =
  ## Milliseconds the caller may sleep before the next iterate.
  tox_iteration_interval(t.raw).int

proc sendLosslessPacket*(t: ToxInstance; friend: uint32; data: seq[byte]): bool =
  var err: Tox_Err_Friend_Custom_Packet
  result = tox_friend_send_lossless_packet(t.raw, friend,
    if data.len > 0: unsafeAddr data[0] else: nil, csize_t data.len, addr err)

proc friendAdd*(t: ToxInstance; addressHex, message: string): uint32 =
  ## Send a friend request to a Tox ID (76 hex chars) carrying `message`
  ## (C: tox_friend_add in client_mode). Returns the friend number.
  if addressHex.len != TOX_ADDRESS_SIZE * 2:
    raise newException(ToxError, "bad Tox ID length: " & $addressHex.len)
  if message.len > TOX_MAX_FRIEND_REQUEST_LENGTH:
    raise newException(ToxError, "friend request message too long")
  var address: array[TOX_ADDRESS_SIZE, uint8]
  for i in 0 ..< TOX_ADDRESS_SIZE:
    address[i] = uint8(parseHexInt(addressHex[i * 2 ..< i * 2 + 2]))
  var err: Tox_Err_Friend_Add
  result = tox_friend_add(t.raw, address,
    if message.len > 0: cast[ptr uint8](unsafeAddr message[0]) else: nil,
    csize_t message.len, addr err)
  if err != TOX_ERR_FRIEND_ADD_OK:
    raise newException(ToxError, "friend_add failed: " & $err)

proc friendByPublicKey*(t: ToxInstance; publicKeyHex: string): uint32 =
  ## The friend number for an existing friend (first 64 hex chars of their
  ## Tox ID) — used when a restart reloads an identity that already sent
  ## the request, since re-sending would fail with ALREADY_SENT.
  var key: array[TOX_PUBLIC_KEY_SIZE, uint8]
  for i in 0 ..< TOX_PUBLIC_KEY_SIZE:
    key[i] = uint8(parseHexInt(publicKeyHex[i * 2 ..< i * 2 + 2]))
  var err: Tox_Err_Friend_By_Public_Key
  result = tox_friend_by_public_key(t.raw, key, addr err)
  if err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK:
    raise newException(ToxError, "friend_by_public_key failed: " & $err)

proc friendDelete*(t: ToxInstance; friend: uint32) =
  ## Drop a friend (C: tox_friend_delete before re-sending a request).
  var err: Tox_Err_Friend_Delete
  discard tox_friend_delete(t.raw, friend, addr err)
  if err != TOX_ERR_FRIEND_DELETE_OK:
    raise newException(ToxError, "friend_delete failed: " & $err)

proc friendAddNoRequest*(t: ToxInstance; publicKeyHex: string): uint32 =
  ## Accept a friend by public key (32-byte hex); returns the friend number.
  var err: Tox_Err_Friend_Add
  var key: array[TOX_PUBLIC_KEY_SIZE, uint8]
  for i in 0 ..< TOX_PUBLIC_KEY_SIZE:
    key[i] = uint8(parseHexInt(publicKeyHex[i * 2 ..< i * 2 + 2]))
  result = tox_friend_add_norequest(t.raw, key, addr err)
  if err != TOX_ERR_FRIEND_ADD_OK:
    raise newException(ToxError, "friend_add_norequest failed: " & $err)
