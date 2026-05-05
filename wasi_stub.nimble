# Package

version       = "0.1.0"
author        = "litlighilit"
description   = "Detect all WASI-related imports in a WebAssembly file, and replace them with stubs that do nothing"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["wasi_stub"]
binDir           = "bin"


# Dependencies

requires "nim > 2.0.8"
