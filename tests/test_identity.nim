## Identity persistence: the same savedata must yield the same Tox ID,
## and a fresh instance must yield a different one.

import std/[os, sequtils, unittest]
import tuntox/tox

let stateFile = getTempDir() / "nim_tuntox_identity_test.bin"

proc runTox(s: seq[byte]): tuple[id: string, data: seq[byte]] =
  let t = newTox(s)
  result = (t.address, t.savedata)
  # t goes out of scope: destructor runs tox_kill

suite "identity":
  test "fresh instance has a 76-hex-char ID":
    let (id, _) = runTox(@[])
    check id.len == 76
    check id.allIt(it in {'0'..'9', 'A'..'F'})

  test "savedata restores the same ID":
    if fileExists(stateFile): removeFile(stateFile)
    let (id1, data) = runTox(@[])
    writeFile(stateFile, data)
    let (id2, _) = runTox(cast[seq[byte]](readFile(stateFile)))
    check id1 == id2

  test "different savedata, different ID":
    let (id1, _) = runTox(@[])
    let (id2, _) = runTox(@[])
    check id1 != id2
