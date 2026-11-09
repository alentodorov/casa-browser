# Casa — handoff

A small native macOS browser (WKWebView) for Alen's iMac: Omarchy-style desktop, AeroSpace tiling,
SketchyBar on top, Flexoki light, JetBrainsMono Nerd Font Bold. A git repo (local only, no remote);
commit and push only when told. The app builds to `~/Applications/Casa.app`, bundle id `com.alentodorov.casa`.

## What Casa is

Design **direction A, "Notch"**, extended on 2026-11-09 by **direction D, "Tiles"** (`mockups/d*`): a
window is moved to AeroSpace workspace 8 and made fullscreen there; inside it, numbered **workspaces**
(Omarchy's, not AeroSpace's) each tile **panes**, browser or terminal, the way Hyprland's dwindle layout
does. A new pane splits the focused one along its longer side and lands right or below; Omarchy's keys
(physical Cmd as Super) move focus, swap, flip, resize, zoom, close and move panes between workspaces.

The only chrome is the 36pt paper strip above the panes: workspace numbers top-left in SketchyBar's
workspace style (1…5 always, dimmed while empty, higher numbers while in use, the current one a filled
square), a black pill at the top centre for the focused pane (lock + host for a browser, console glyph +
folder for a terminal, a zoom glyph while zoomed; hover widens a browser pill to back / forward / reload
and the path), and a download pill top right while a download runs. cmd-L turns the pill into the
palette, cmd-F into find. Tiled panes have 6pt paper gaps, a 2pt border in Omarchy's Flexoki Light accent
(blue `#205EA6`) on the focused one and 1pt base150 on the rest (screenshots `28`–`42` predate this and
show the earlier ink border; `47` shows the blue); a single pane is edge to edge. ctrl-tab held shows the workspace switcher. Calm and
useful; nothing "fun but pointless".

- `PLAN.md` — the original three directions and the chosen one.
- `mockups/` — `a*-notch-*.png` (approved v1) and `d*-tiles-*.png` (approved tiles); `render.sh` /
  `render-tiles.sh` re-render them.
- `screenshots/` — every state captured from the real app (see Testing).

## Architecture (`src/`, plain `swiftc`, no Xcode project)

| file | what |
|---|---|
| `main.swift` | `AppDelegate`: windows, the whole menu (every shortcut lives here), session save/restore, URL open (http/https registered in Info.plist but Casa is **not** set as default browser), `place(_:)` (runs `aerospace move-node-to-workspace --focus-follows-window --window-id N 8` then `aerospace fullscreen on --window-id N` for each new window, 4 retries; `AppDelegate.workspace` is the "8"), the `CASA_DEBUG` channel. Starts `KeySwap`. |
| `KeySwap.swift` | CGEvent tap (`.cghidEventTap`, head insert) active only while Casa is frontmost. Alen's Karabiner swaps cmd/alt globally so physical Cmd drives AeroSpace; this swaps them back inside Casa: generic flags, device-specific bits, and modifier keycodes 55/58, 54/61 on flagsChanged. So in Casa physical Cmd = cmd (Omarchy's Super) and physical Option = alt (reaches AeroSpace). Needs Accessibility: prompts at launch, polls `AXIsProcessTrusted` every 2s until granted. |
| `Layout.swift` | The tiling model. `Pane` (a `Tab` or a `TerminalView` in a `PaneBox`, with published title/host), `Node` (leaf or split with axis + ratio), `Workspace` (number, tree, focused, zoomed): `insert` (dwindle split), `remove` (sibling collapses up, focus to the nearest pane), `swap`, `toggleSplit`, `moveDivider` (nearest ancestor split on that axis, by a signed delta), `layout(in:)` (frames with 6pt gaps, zoom), `neighbour(of:_:)` (adjacent across the gap, overlapping, preferring the one in line with the centre), session encode/restore. |
| `BrowserWindow.swift` | `WindowState` (workspaces, current, focused pane, mode, palette rows, find, download) and `BrowserWindow: NSWindow`: the chromeless window (hidden transparent title bar, traffic lights hidden, min 480×320), `TilesView` (flipped, hosts the current workspace's pane boxes, relayouts on resize), the strip and overlay hosting views (both with `safeAreaRegions = []`), every workspace / pane operation, three local event monitors (ctrl release commits the switcher; a click focuses the pane under it; cmd-arrows / cmd-shift-arrows / cmd-shift-1…9 are taken ahead of the web view and Ghostty), a `makeFirstResponder` override so the focused pane and its outline follow keyboard focus however it moves, overlays, downloads, session, the `@objc` menu actions. |
| `Chrome.swift` | SwiftUI: `StripView` (progress line, `WorkspaceNumbers`, `PillView` / `TerminalPill`, `FindPill`, `StatusPills`), `OverlayView` (`PaletteView`, `SwitcherView` over workspaces), `KeyField` (an AppKit text field so arrows / enter / esc are reliable). |
| `Tab.swift` | `blankHTML`, the page a new pane starts on: Casa's keys as an Omarchy Super+K style sheet (paper, ink, grey, the Nerd Font; three columns, one when narrow). One `WKWebView` per browser pane: KVO (title, url, progress, canGoBack…), navigation / UI delegates (pop-ups → a new pane beside this one, JS dialogs → sheets), `WKDownload` to `~/Downloads`, find with a JS-counted "n/m", zoom per host, Safari-like UA. Private windows use `WKWebsiteDataStore.nonPersistent()`. |
| `Console.swift` | libghostty for terminal panes. `GhosttyRuntime` (init, config from `~/.config/ghostty/config` via libghostty's loader, app, runtime callbacks: wakeup, action, clipboard, close). `TerminalView: NSView, NSTextInputClient`, a cut-down port of Ghostty's `SurfaceView_AppKit.swift`: the core attaches its own Metal layer; the view forwards size, scale, focus, keys, mouse, scroll, copy/paste, reports `pwd` (shell integration) through `onPwd`. Shell exit closes the pane; cmd-click links open as browser panes; menu shortcuts beat Ghostty's own cmd keybinds. |
| `History.swift` | `~/.local/state/casa/`: `history.jsonl`, `session.json` (v2: windows → workspaces → pane trees; v1's url list still loads), `zoom.json`. |
| `Theme.swift` | Flexoki colours, font (the Nerd Font **Propo** build, see below), Nerd Font glyphs, `persistentWorkspaces = 5`, paths. |

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
`workspace[:URL]` (cmd-T), `ws:N` (cmd-N), `move-ws:N` (cmd-shift-N), `browser[:URL]` (cmd-shift-enter),
`term` (cmd-enter), `term-type:LINE` (types it and Enter into the focused terminal), `closepane`,
`reopen`, `focus:l|r|u|d`, `swap:l|r|u|d`, `flip`, `zoom`, `resize:w|h,DELTA` (moves the divider by DELTA), `private`, `newwindow`,
`frame:x,y,w,h`, `load:URL`, `dump` (NSLogs every workspace, pane and the mode), `close`, `quit`.
`type:>` must be quoted in zsh.

Screenshots without stealing focus: find the window id with `CGWindowListCopyWindowInfo` (owner "Casa",
layer 0) or `aerospace list-windows --all | grep Casa`, then

    screencapture -l<windowID> -o -x out.png

**A launch pulls focus to workspace 8** (that is the feature). During a scripted test, switch back to
Alen's workspace the moment the window appears (`aerospace workspace N`): otherwise his reflex
Cmd+digit to get back lands in Casa as cmd-N and creates a blank workspace with the palette, which
looked like a bug twice before it was understood. Wait for the process to exit (`pgrep`) before
touching `session.json`, since quitting writes it. For a narrow tile: `aerospace layout floating
--window-id N`, `frame:200,100,640,800`, then `aerospace layout tiling --window-id N` and `aerospace
fullscreen on --window-id N`. The debug path sets state directly, so it doesn't exercise real key events.

## Keyboard map

Inside Casa `KeySwap` makes physical Cmd = cmd and physical Option = alt (AeroSpace). Casa binds no
alt-* keys; `~/.aerospace.toml` owns `alt-*`, `alt-shift-*`, `alt-cmd-*`, `alt-ctrl-*`, `ctrl-cmd-tab`.
The pane keys are Omarchy's with physical Cmd as Super.

| keys | does |
|---|---|
| cmd-enter, ctrl-` | new terminal pane, split from the focused pane (starts in the focused terminal's directory, else `~/projects`) |
| cmd-shift-enter, cmd-shift-B | new browser pane, palette open |
| cmd-T | new workspace at the lowest free number, blank pane, palette open |
| cmd-W | close pane; the last pane closes its workspace, the last workspace the window |
| cmd-shift-T | reopen the last closed browser pane's URL as a new pane |
| cmd-arrows | focus the pane in that direction |
| cmd-shift-arrows | swap with the pane in that direction |
| cmd-J | flip the focused pane's split |
| cmd-shift-F | zoom the focused pane to the whole workspace, again to unzoom |
| cmd-- / cmd-= | move the divider 100pt left / right; with shift, up / down. As Hyprland's `resizeactive` does in dwindle (checked against `DwindleLayout::resizeActiveWindow`): the nearest split on that axis moves, so a pane left of the divider shrinks on cmd-- while one right of it grows. Alen's `aerospace-resize` helper does the same for AeroSpace |
| cmd-1…9 | workspace N (an empty one opens blank with the palette) |
| cmd-shift-1…9 | move the focused pane to workspace N and follow (handled in `KeySwap`'s event tap, because Shottr owns cmd-shift-1/2 and macOS cmd-shift-3/4/5 as global hotkeys that would otherwise win; so it needs Accessibility, like the swap itself) |
| ctrl-tab / ctrl-shift-tab | next / previous workspace; held, the switcher stays open until ctrl is released |
| cmd-shift-] / cmd-shift-[ | next / previous workspace |
| cmd-L / cmd-K | palette, address mode / panes + `>` commands (from a terminal pane the result opens in a new browser pane) |
| cmd-[ / cmd-] | back / forward (two-finger swipe too) |
| cmd-R / cmd-shift-R / cmd-. | reload / ignoring cache / stop |
| cmd-F, cmd-G, cmd-shift-G, esc | find, next, previous, close |
| cmd-0 | reset page zoom (zoom in/out: pinch, or the palette's `>zoom in` / `>zoom out`) |
| cmd-N / cmd-shift-N | new window / private window (both on workspace 8, AeroSpace-fullscreen) |
| cmd-shift-C, cmd-shift-D, cmd-shift-I | copy URL, reveal latest download, Web Inspector |
| cmd-Q, cmd-C/V/X/A/Z, cmd-H | standard (copy/paste also in terminals) |

## Status

**Done and screenshot-tested** (`screenshots/`): `01`–`10`, `15`–`17`, `22`–`27` the v1 chrome (palette,
switcher, find, private, download, narrow, restore; a few older ones still show the dropped music pill);
`28`–`42` the tiles: restore, terminal pane, three panes, focus, swap, flip, resize, zoom, move to
workspace 4, switcher, palette over panes, pane closed, narrow, terminal exit, v2 restore; `43`–`46` the
new-tab shortcut sheet (with the palette, alone, split with a terminal, narrow).

**Untested or caveated**

- `KeySwap` has not been tried with real keys; it needs Alen to grant Accessibility to Casa first.
  Verify: physical Cmd-T opens a workspace, physical Cmd-L the palette, physical Option-1 switches
  AeroSpace workspace.
- The menu shortcuts and the key monitor (cmd-arrows, cmd-shift-arrows, cmd-shift-digits) were only
  driven through the debug channel, not real key events; cmd-arrows are taken even inside a page's text
  field, by design. Give them a hands-on pass.
- Dark pages: the 36pt strip is paper by design, so a dark page gets a paper band on top.
- Find's "n/m" counts page text, so hidden text can inflate it.
- Web Inspector uses WebKit's private `_inspector`; right-click → Inspect Element is the fallback.
- Terminal panes auto-approve Ghostty's clipboard confirmations; Ghostty's own cmd keybinds are
  shadowed by Casa's menu.
- No extensions (WebKit): 1Password only via universal autofill.
- Nits: disabled back/forward at 30% are very faint on black; the palette field's selection colour
  follows the system accent.

Fixed along the way (2026-11-09): hosting views honoured the hidden title bar as a 32pt safe area (pill
sat 16pt low); the plain Nerd Font clipped wide icons (ink wider than advance), hence the Propo build;
two wrong glyph codepoints (look them up in nerd-fonts' `glyphnames.json`, not from memory).

**Later**: Omarchy's groups (tabs inside a pane), pseudo, floating and mouse drag/resize (AeroSpace does
those for the whole window), content blocker (`WKContentRuleList` from an EasyList conversion), real
favicons (now letter tiles by host), bookmarks / pinned panes, user styles, picture in picture, a `casa`
CLI (`casa open URL`, `casa tabs`) for scripts and SketchyBar, an app icon, pointing AeroSpace's
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
