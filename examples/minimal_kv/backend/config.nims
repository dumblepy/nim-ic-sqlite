import std/os

# SQLite include paths, C shim compilation, and the prebuilt archive are set up
# by ic_sqlite/ffi/linkage.nim when `import ic_sqlite` is used.
let icSqliteRoot = "/application"
switch("path", icSqliteRoot / "src")

--mm: "orc"
--threads: "off"
--cpu: "wasm32"
--os: "linux"
--nomain
--cc: "clang"
--define: "useMalloc"

switch("define", "wasi")
switch("define", "rustcryptoWasi")
switch("passC", "-target wasm32-wasip1")
switch("passL", "-target wasm32-wasip1")
switch("passL", "-static")
switch("passL", "-nostartfiles")
switch("passL", "-Wl,--no-entry")
switch("passC", "-fno-exceptions")
switch("passL", "-Wl,--allow-multiple-definition")

let cHeadersPath = "/root/.ic-c-headers"
switch("passC", "-I" & cHeadersPath)
switch("passL", "-L" & cHeadersPath)
let icWasiPolyfillPath = getEnv("IC_WASI_POLYFILL_PATH")
switch("passL", "-L" & icWasiPolyfillPath)
switch("passL", "-lic_wasi_polyfill")
let wasiSysroot = getEnv("WASI_SDK_PATH") / "share/wasi-sysroot"
switch("passC", "--sysroot=" & wasiSysroot)
switch("passL", "--sysroot=" & wasiSysroot)
switch("passC", "-I" & wasiSysroot & "/include")
switch("passC", "-D_WASI_EMULATED_SIGNAL")
switch("passL", "-lwasi-emulated-signal")
