# Vendored libghostty

- `GhosttyKit.xcframework/` — libghostty (Ghostty's terminal core as a static library, `libghostty-internal.a`,
  arm64, release) plus `ghostty.h` and a module map, built from the v1.4.0 source in `ghostty/`.
- `ghostty-share/` — the resources the library needs at run time: `terminfo` (xterm-ghostty) and
  `ghostty/{themes,shell-integration}`. `build.sh` copies them into `Casa.app/Contents/Resources` in the
  same layout as Ghostty.app, which is where libghostty looks relative to the executable.
- `ghostty/` — the source, a shallow clone of tag v1.4.0 (the version installed in /Applications), kept
  for rebuilds. Its `.zig-cache` was removed; a rebuild recreates it (~1 GB).

Not in git: `ghostty/` (670 MB, its own repo) and `GhosttyKit.xcframework/macos-arm64/libghostty-internal.a`
(143 MB). A fresh checkout recreates both with:

    git clone --depth 1 --branch v1.4.0 https://github.com/ghostty-org/ghostty vendor/ghostty

and then the rebuild below.

## Rebuilding

Needs zig 0.17 (`brew install zig`) and Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`,
a one-off 700 MB download; the shader compile fails without it).

    cd vendor/ghostty
    zig build -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework=true \
      -Demit-macos-app=false -Dxcframework-target=native
    rm -rf ../GhosttyKit.xcframework ../ghostty-share
    cp -R macos/GhosttyKit.xcframework ../GhosttyKit.xcframework
    mkdir -p ../ghostty-share && cp -R zig-out/share/ghostty zig-out/share/terminfo ../ghostty-share/

To move to a newer Ghostty, check out its tag in `ghostty/` (its `build.zig.zon` says which zig it needs),
rebuild, and re-check `src/Console.swift` against `include/ghostty.h` and
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`, which it is a cut-down port of.
