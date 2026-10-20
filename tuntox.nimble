# Package
version       = "0.1.0"
author        = "Luis Araujo"
description   = "Tunnel TCP over Tox — tuntox translated to a Nim library"
license       = "GPL-3.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0"

task test, "Run the test suite":
  for f in listFiles("tests"):
    if f.endsWith(".nim") and f.startsWith("tests/test_"):
      exec "nim c -r --path:src --hints:off " & f
