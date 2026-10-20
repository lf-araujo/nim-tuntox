## Protocol codec: round-trips for every packet type, header validation,
## and the REQUESTTUNNEL payload layout the C server parses.

import std/[strutils, unittest]
import tuntox/protocol

proc frame(pt, connId: uint16; data: seq[byte] = @[]): Frame =
  Frame(friendnumber: 7, magic: protocolMagic, packetType: pt,
    connId: connId, data: data)

proc roundTrip(pt, connId: uint16; data: seq[byte] = @[]): Frame =
  decodeFrame(7'u32, encodeFrame(frame(pt, connId, data)))

suite "protocol":
  test "header round-trips for every packet type":
    for pt in [packetTypePong, packetTypePing, packetTypeRequestTunnel,
               packetTypeDenyTunnel, packetTypeAckTunnel, packetTypeTcp,
               packetTypeTcpFin]:
      let f = roundTrip(pt, 0x1234'u16)
      check f.magic == protocolMagic
      check f.packetType == pt
      check f.connId == 0x1234
      check f.friendnumber == 7
      check f.data.len == 0

  test "TCP payload round-trips":
    let payload = @[byte 1, 2, 3, 4, 5]
    let f = roundTrip(packetTypeTcp, 42'u16, payload)
    check f.data == payload

  test "wire layout is big-endian with 8-byte header":
    let buf = encodeFrame(frame(packetTypePing, 0x0102'u16, @[byte 0xaa]))
    check buf == @[byte 0xa2, 0x6b, 0x01, 0x08, 0x01, 0x02, 0x00, 0x01, 0xaa]

  test "trailing bytes beyond declared data length are ignored":
    var buf = encodeFrame(frame(packetTypePing, 1'u16, @[byte 9]))
    buf.add [byte 1, 2, 3]
    let f = decodeFrame(0'u32, buf)
    check f.data == @[byte 9]

  test "bad magic is rejected":
    var buf = encodeFrame(frame(packetTypePing, 1'u16))
    buf[0] = 0x12
    buf[1] = 0x34
    expect ValueError:
      discard decodeFrame(0'u32, buf)

  test "protocol v1 magic gets a distinct error":
    var buf = encodeFrame(frame(packetTypePing, 1'u16))
    buf[0] = 0xa2
    buf[1] = 0x6a
    try:
      discard decodeFrame(0'u32, buf)
      fail()
    except ValueError as e:
      check "old protocol" in e.msg

  test "short frame is rejected":
    expect ValueError:
      discard decodeFrame(0'u32, [byte 0xa2, 0x6b, 0x01])

  test "declared length larger than the buffer is rejected":
    let buf = [byte 0xa2, 0x6b, 0x01, 0x08, 0x00, 0x01, 0x00, 0x40]
    expect ValueError:
      discard decodeFrame(0'u32, buf)

  test "oversized data is rejected at encode time":
    expect ValueError:
      discard encodeFrame(frame(packetTypeTcp, 1'u16,
        newSeq[byte](maxDataLength + 1)))

suite "request tunnel frame":
  test "payload matches what the C server parses":
    let f = makeRequestTunnel(3'u32, "203.0.113.7", 22'u16, 0xdeadbeef'u32)
    let buf = encodeFrame(f)
    # C: frame->connid = remote_port, data = BE32 forward id + host string
    check buf[4] == 0 and buf[5] == 22                # connid = port
    check buf[6] == 0 and buf[7] == byte(4 + 11)      # data_length
    check buf[8] == 0xde and buf[9] == 0xad and
      buf[10] == 0xbe and buf[11] == 0xef             # INT32_AT(data, 0)
    check buf[12 ..^ 1] == @[byte 50, 48, 51, 46, 48, 46, 49, 49, 51, 46, 55]
    # and the C-side parse in Nim agrees
    let r = parseRequestTunnel(decodeFrame(3'u32, buf))
    check r.host == "203.0.113.7"
    check r.port == 22
    check r.forwardId == 0xdeadbeef'u32

  test "hostname round-trips":
    for host in ["localhost", "example.com", "10.0.0.1"]:
      let r = parseRequestTunnel(
        decodeFrame(0'u32, encodeFrame(makeRequestTunnel(0'u32, host, 443'u16, 1'u32))))
      check r.host == host
      check r.port == 443
      check r.forwardId == 1

  test "request payload shorter than 4 bytes is rejected":
    expect ValueError:
      discard parseRequestTunnel(frame(packetTypeRequestTunnel, 1'u16, @[byte 1]))
