## tuntox wire protocol, v2 (magic 0xa26b).
##
## Frame layout on the wire (big-endian, from main.h/main.c):
##
##   offset 0  magic        (2 bytes, 0xa26b; 0xa26a is protocol v1)
##   offset 2  packet type  (2 bytes)
##   offset 4  connid       (2 bytes — tunnel id, or remote port for REQUESTTUNNEL)
##   offset 6  data length  (2 bytes)
##   offset 8  data
##
## REQUESTTUNNEL carries its payload in `data`: a 4-byte big-endian
## forward id followed by the remote host as a string; the remote port
## rides in `connid` (see send_tunnel_request_packet /
## handle_request_tunnel_frame in main.c).

import std/strutils
import tox_raw

const
  protocolMagicV1* = 0xa26a'u16
  protocolMagic* = 0xa26b'u16
  packetTypePong* = 0x0100'u16
  packetTypePing* = 0x0108'u16
  packetTypeRequestTunnel* = 0x0602'u16
  packetTypeDenyTunnel* = 0x0604'u16
  packetTypeAckTunnel* = 0x0610'u16
  packetTypeTcp* = 0x0600'u16
  packetTypeTcpFin* = 0x0601'u16

  bufferOffset* = 8
  maxDataLength* = TOX_MAX_CUSTOM_PACKET_SIZE - bufferOffset

type
  Frame* = object
    friendnumber*: uint32
    magic*: uint16
    packetType*: uint16
    connId*: uint16
    data*: seq[byte]

func be16(buf: openArray[byte]; pos: int): uint16 =
  uint16(buf[pos]) shl 8 or uint16(buf[pos + 1])

func be32*(buf: openArray[byte]; pos: int): uint32 =
  uint32(buf[pos]) shl 24 or uint32(buf[pos + 1]) shl 16 or
    uint32(buf[pos + 2]) shl 8 or uint32(buf[pos + 3])

proc encodeFrame*(f: Frame): seq[byte] =
  ## Serialize a frame: 8-byte big-endian header followed by `data`.
  if f.data.len > maxDataLength:
    raise newException(ValueError,
      "frame data too big: " & $f.data.len & " bytes, max " & $maxDataLength)
  result = newSeq[byte](bufferOffset + f.data.len)
  result[0] = uint8(f.magic shr 8)
  result[1] = uint8(f.magic and 0xff)
  result[2] = uint8(f.packetType shr 8)
  result[3] = uint8(f.packetType and 0xff)
  result[4] = uint8(f.connId shr 8)
  result[5] = uint8(f.connId and 0xff)
  result[6] = uint8(f.data.len shr 8)
  result[7] = uint8(f.data.len and 0xff)
  for i, b in f.data:
    result[bufferOffset + i] = b

proc decodeFrame*(friendnumber: uint32; buf: openArray[byte]): Frame =
  ## Parse a lossless packet into a frame. Raises ValueError on a bad
  ## header (including protocol v1 magic, which gets its own message).
  if buf.len < bufferOffset:
    raise newException(ValueError,
      "frame too small: " & $buf.len & " bytes, expected at least " & $bufferOffset)
  let magic = be16(buf, 0)
  if magic == protocolMagicV1:
    raise newException(ValueError,
      "remote uses old protocol version 1 (magic 0xa26a); upgrade required")
  if magic != protocolMagic:
    raise newException(ValueError,
      "bad protocol magic 0x" & toHex(magic.int, 4))
  let dataLen = be16(buf, 6)
  if dataLen > maxDataLength:
    raise newException(ValueError,
      "declared data length too big: " & $dataLen & ", max " & $maxDataLength)
  if buf.len < bufferOffset + dataLen.int:
    raise newException(ValueError,
      "frame too small: " & $buf.len & " bytes, header declares " &
      $(bufferOffset + dataLen.int))
  Frame(
    friendnumber: friendnumber,
    magic: magic,
    packetType: be16(buf, 2),
    connId: be16(buf, 4),
    data: buf[bufferOffset ..< bufferOffset + dataLen],
  )

proc makeRequestTunnel*(friendnumber: uint32; remoteHost: string;
    remotePort: uint16; forwardId: uint32): Frame =
  ## Build a REQUESTTUNNEL frame exactly as the C client does: connid =
  ## remote port, data = 4-byte big-endian forward id + host string.
  var data = newSeq[byte](4 + remoteHost.len)
  data[0] = uint8(forwardId shr 24)
  data[1] = uint8(forwardId shr 16 and 0xff)
  data[2] = uint8(forwardId shr 8 and 0xff)
  data[3] = uint8(forwardId and 0xff)
  for i, ch in remoteHost:
    data[4 + i] = byte(ch)
  Frame(
    friendnumber: friendnumber,
    magic: protocolMagic,
    packetType: packetTypeRequestTunnel,
    connId: remotePort,
    data: data,
  )

proc parseRequestTunnel*(f: Frame): tuple[host: string; port: uint16;
    forwardId: uint32] =
  ## Decode a REQUESTTUNNEL frame the way handle_request_tunnel_frame
  ## does: forward id from the first 4 data bytes, host from the rest,
  ## port from connid.
  if f.packetType != packetTypeRequestTunnel:
    raise newException(ValueError, "not a REQUESTTUNNEL frame")
  if f.data.len < 4:
    raise newException(ValueError,
      "REQUESTTUNNEL data too small: " & $f.data.len & " bytes, expected at least 4")
  var host = newString(f.data.len - 4)
  for i, b in f.data[4 ..^ 1]:
    host[i] = char(b)
  result = (host: host, port: f.connId, forwardId: be32(f.data, 0))
