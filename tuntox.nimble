# Package
version       = "0.1.0"
author        = "Luis Araujo"
description   = "Tunnel TCP over Tox — tuntox translated to a Nim library"
license       = "GPL-3.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0"

before install:
  exec "PKG_CONFIG_PATH=" & getenv("HOME") & "/.local/lib64/pkgconfig nim c -r tests/test_identity.nim"
