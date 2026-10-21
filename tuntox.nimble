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

task toxcore, "Fetch and build c-toxcore v0.2.19 into vendor/ when pkg-config can't find it":
  let found = gorgeEx("pkg-config --exists toxcore")
  if found.exitCode == 0:
    echo "toxcore: already visible to pkg-config, nothing to do"
  else:
    if not dirExists("vendor/c-toxcore"):
      mkDir("vendor")
      exec "git clone --depth 1 --branch v0.2.19 --recurse-submodules " &
        "--shallow-submodules " &
        "https://github.com/TokTok/c-toxcore vendor/c-toxcore"
    else:
      exec "git -C vendor/c-toxcore submodule update --init --depth 1"
    let prefix = getCurrentDir() & "/vendor"
    exec "cmake -S vendor/c-toxcore -B vendor/c-toxcore/_build " &
      "-DCMAKE_INSTALL_PREFIX=" & prefix & " -DCMAKE_BUILD_TYPE=Release " &
      "-DENABLE_STATIC=ON -DENABLE_SHARED=OFF -DBUILD_TOXAV=OFF " &
      "-DMUST_BUILD_TOXAV=OFF -DUNITTEST=OFF -DAUTOTEST=OFF " &
      "-DBOOTSTRAP_DAEMON=OFF -DDHT_BOOTSTRAP=ON"
    exec "cmake --build vendor/c-toxcore/_build --parallel"
    exec "cmake --install vendor/c-toxcore/_build"
    var pcDir = prefix & "/lib64/pkgconfig"
    if not dirExists(pcDir):
      pcDir = prefix & "/lib/pkgconfig"
    echo "toxcore: installed under " & prefix
    echo "  export PKG_CONFIG_PATH=" & pcDir & ":$PKG_CONFIG_PATH"
