# Casa — handoff

A small native macOS browser (WKWebView) for Alen's iMac: Omarchy-style desktop, AeroSpace tiling,
SketchyBar on top, Flexoki light, JetBrainsMono Nerd Font Bold. A git repo (local only, no remote);
commit and push only when told. The app builds to `~/Applications/Casa.app`, bundle id `com.alentodorov.casa`.

## What Casa is

Design **direction A, "Notch"**: no chrome except what floats in the page's top 36pt strip
(`WKWebView.obscuredContentInsets`, macOS 26): a black pill at the top centre with lock, host and
`3/7`; hover widens it to back / forward / reload and the path; cmd-L turns it into the palette, cmd-F
into find. Tab numbers sit top-left in SketchyBar's workspace style. A download pill sits top right
while a download runs. (The timer and now-playing pills from the mockups were dropped on 2026-11-09;
the mockups still show them.) Tabs are keyboard-first; ctrl-tab held shows the switcher. One window = one tab
group; every window is moved to AeroSpace workspace 8 and made fullscreen there (focus follows it). A libghostty console (zsh) slides up as a
split under the page on cmd-J / cmd-enter / ctrl-`. Calm and useful; nothing "fun but pointless".

- `PLAN.md` — the three directions, the chosen one, keyboard map, v1 / later.
- `mockups/` — the approved mockups (`a*-notch-*.png`); `mockups/render.sh` re-renders them.
- `screenshots/` — every v1 state captured from the real app (see Testing).

## Architecture (`src/`, plain `swiftc`, no Xcode project)

| file | what |
|---|---|
| `main.swift` | `AppDelegate`: windows, the whole menu (every shortcut lives here), session save/restore, URL open (http/https registered in Info.plist but Casa is **not** set as default browser), `place(_:)` (runs `aerospace move-node-to-workspace --focus-follows-window --window-id N 8` then `aerospace fullscreen on --window-id N` for each new window, 4 retries; `AppDelegate.workspace` is the "8"), the `CASA_DEBUG` channel. Starts `KeySwap`. |
| `KeySwap.swift` | CGEvent tap (`.cghidEventTap`, head insert) active only while Casa is frontmost. Alen's Karabiner swaps cmd/alt globally so physical Cmd drives AeroSpace; this swaps them back inside Casa: generic flags, device-specific bits, and modifier keycodes 55/58, 54/61 on flagsChanged. So in Casa physical Cmd = cmd (Chrome-like) and physical Option = alt (reaches AeroSpace). Needs Accessibility: prompts at launch, polls `AXIsProcessTrusted` every 2s until granted. |
| `BrowserWindow.swift` | `WindowState` (tabs, mode, palette rows, find, download pill, console flag) and `BrowserWindow: NSWindow` (widgets' chromeless window: hidden transparent title bar, traffic lights hidden, min 480×320). Holds an `NSSplitView` (page over console), the strip hosting view, the overlay hosting view (palette / switcher), all tab actions, and the `@objc` menu actions. |
| `Chrome.swift` | SwiftUI: `StripView` (progress line, `TabNumbers`, `PillView`, `FindPill`, `StatusPills`), `OverlayView` (`PaletteView`, `SwitcherView`), `KeyField` (an AppKit text field so arrows / enter / esc are reliable). `TabNumbers`: numbers top-left, current tab = U+F14FB filled square, click selects, hover shows the title, hidden while palette or switcher is open. |
| `Tab.swift` | One `WKWebView` per tab: KVO (title, url, progress, canGoBack…), navigation / UI delegates (popups → new tab, JS dialogs → sheets), `WKDownload` to `~/Downloads`, find with a JS-counted "n/m", zoom per host, Safari-like UA. Private windows use `WKWebsiteDataStore.nonPersistent()`. |
| `Console.swift` | libghostty. `GhosttyRuntime` (init, config from `~/.config/ghostty/config` via libghostty's loader, app, runtime callbacks: wakeup, action, clipboard, close). `TerminalView: NSView, NSTextInputClient`, a cut-down port of Ghostty's `SurfaceView_AppKit.swift`: the core attaches its own Metal layer; the view forwards size, scale, focus, keys, mouse, scroll, copy/paste. Shell exit closes the console; cmd-click links open as Casa tabs; menu shortcuts beat Ghostty's own cmd keybinds. |
| `History.swift` | `~/.local/state/casa/`: `history.jsonl`, `session.json`, `zoom.json`. |
| `Theme.swift` | Flexoki colours, font, Nerd Font glyphs, paths. |

### vendor/

- `GhosttyKit.xcframework/` — libghostty 1.4.0 static lib (arm64, release) + `ghostty.h` + module map.
- `ghostty-share/` — terminfo, themes, shell-integration; `build.sh` copies them into
  `Casa.app/Contents/Resources` in Ghostty.app's layout (libghostty finds them relative to the exe).
- `ghostty/` — shallow clone of tag v1.4.0 (matches the installed Ghostty). `vendor/README.md` has the recipe:

      brew install zig                                   # 0.17.x, Ghostty 1.4.0 needs 0.17
      xcodebuild -downloadComponent MetalToolchain       # once; the shader compile fails without it
      cd vendor/ghostty
      zig build -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework=true \
        -Demit-macos-app=false -Dxcframework-target=native
      cp -R macos/GhosttyKit.xcframework ../GhosttyKit.xcframework
      cp -R zig-out/share/ghostty zig-out/share/terminfo ../ghostty-share/

### build.sh

`./build.sh` compiles `src/*.swift` with `-I/-L` into the xcframework, `-lghostty-internal -lc++` and the
Metal / CoreText / CoreVideo / Carbon frameworks, writes Info.plist, copies the ghostty resources, and
signs with the keychain's **"Apple Development"** identity (ad-hoc if none) so the TCC Accessibility
grant survives rebuilds. About a minute.

## Build, run, test

    ./build.sh
    open -a Casa                      # or ~/Applications/Casa.app/Contents/MacOS/casa
    CASA_DEBUG=1 ~/Applications/Casa.app/Contents/MacOS/casa &   # with the debug channel

Debug channel (only with `CASA_DEBUG=1`): a distributed notification named
`com.alentodorov.casa.debug` whose `object` is the command string. Post one from Swift:

    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.alentodorov.casa.debug"), object: "palette", userInfo: nil, deliverImmediately: true)

Commands (`name` or `name:arg`), all on the key window: `palette`, `palette-tabs`, `type:TEXT` (palette
or find field), `up`, `down`, `enter`, `esc`, `find`, `switcher`, `commit`, `hover:on|off`,
`newtab[:URL]`, `closetab`, `reopen`, `select:N`, `private`, `newwindow`, `console`,
`console-type:LINE` (types it and Enter), `console-height:PX`, `frame:x,y,w,h`, `load:URL`, `close`, `quit`.
`type:>` must be quoted in zsh.

Screenshots without stealing focus: find the window id with `CGWindowListCopyWindowInfo` (owner "Casa",
layer 0) or `aerospace list-windows --all | grep Casa`, then

    screencapture -l<windowID> -o -x out.png

For a narrow tile: `aerospace layout floating --window-id N`, `frame:200,100,640,800`, then
`aerospace layout tiling --window-id N`. Every window lands on workspace 8 and focuses it (switch back
with `aerospace workspace N`); quit when done.
The debug path sets state directly, so it doesn't exercise real key events.

## Keyboard map

Inside Casa `KeySwap` makes physical Cmd = cmd and physical Option = alt (AeroSpace). Casa binds no
alt-* keys; `~/.aerospace.toml` owns `alt-*`, `alt-shift-*`, `alt-cmd-*`, `alt-ctrl-*`, `ctrl-cmd-tab`.

| keys | does |
|---|---|
| cmd-L | palette, address mode (URL selected) |
| cmd-K | palette, tabs + `>` commands |
| cmd-T, cmd-shift-enter | new tab (blank, palette opens) |
| cmd-W / cmd-shift-W / cmd-shift-T | close tab / close window / reopen closed tab |
| cmd-N / cmd-shift-N | new window / private window (both on workspace 8, AeroSpace-fullscreen) |
| cmd-1…8, cmd-9 | tab N, last tab |
| ctrl-tab / ctrl-shift-tab | next / previous; held, the switcher stays open until ctrl is released |
| cmd-shift-] / cmd-shift-[ | next / previous tab |
| cmd-[ / cmd-] | back / forward (two-finger swipe too) |
| cmd-R / cmd-shift-R / cmd-. | reload / ignoring cache / stop |
| cmd-F, cmd-G, cmd-shift-G, esc | find, next, previous, close |
| cmd-= / cmd-- / cmd-0 | zoom in / out / reset, remembered per host |
| cmd-shift-C | copy URL |
| cmd-shift-D | reveal latest download / open ~/Downloads |
| cmd-shift-I | Web Inspector |
| cmd-J, cmd-enter, ctrl-` | toggle console |
| cmd-Q, cmd-C/V/X/A/Z, cmd-H | standard (copy/paste also in the console) |

## Status

**Done and screenshot-tested** (`screenshots/01`–`27`): launch with palette, browsing, pill rest and
hover, palette (address, tabs, commands), switcher, find with count, new / close / reopen tab, private
window, download pill, console open / command / resized / closed / shell exit, narrow 640 tile, session
restore. `01`–`04` and `15` were re-shot on 2026-11-09 with the tab numbers, workspace-8 fullscreen and no
widget pills; the music pill still shows in some of the other shots from before the widgets were dropped.

**Untested or caveated**

- `KeySwap` has not been tried with real keys; it needs Alen to grant Accessibility to Casa first.
  Verify: physical Cmd-T opens a tab, physical Cmd-L the palette, physical Option-1 switches workspace.
- The menu shortcuts, ctrl-tab-held switcher and console typing were only driven through the debug
  channel, not real key events. Give them a hands-on pass.
- **Dark pages** (see `04-three-tabs.png`, ghostty.org): the 36pt strip shows the web view's
  `underPageBackgroundColor` (paper), not the page, so a dark page gets a paper band on top and the
  ink tab numbers sit on its edge. Needs a design call: tint the strip from the page (`WKWebView.themeColor`
  / a sampled colour) or switch the numbers to paper over dark pages. Not changed.
- Find's "n/m" counts page text, so hidden text can inflate it.
- Web Inspector uses WebKit's private `_inspector`; right-click → Inspect Element is the fallback.
- The console auto-approves Ghostty's clipboard confirmations; Ghostty's own cmd keybinds (cmd-K
  clear, font size) are shadowed by Casa's menu.
- No extensions (WebKit): 1Password only via universal autofill.

**Later**: content blocker (`WKContentRuleList` from an EasyList conversion), real favicons (now letter
tiles by host), bookmarks / pinned tabs, moving tabs between windows, user styles, picture in picture,
a `casa` CLI (`casa open URL`, `casa tabs`) for scripts and SketchyBar, an app icon, pointing AeroSpace's
`alt-shift-enter` at Casa instead of Chrome (Alen's call, in his dotfiles).

## Alen's working preferences

- Show designs (rendered mockups / screenshots) and get a yes before building or changing UI.
- After any UI change, test every state with screenshots (rest, hover, click, loading, idle, narrow…)
  and check them yourself before calling it done.
- Don't change chezmoi (`~/.local/share/chezmoi`), `~/.aerospace.toml`, SketchyBar or Karabiner unless
  asked; don't apply chezmoi.
- Commit and push only when told.
- When opening something in Preview for him, open it in the background and move its window to his
  current AeroSpace workspace; don't steal focus.
- Keep it calm: he rejects widgets that show too much or are fun but pointless.
- No Homebrew installs without asking (zig was approved for libghostty).
