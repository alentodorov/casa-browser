# Casa — plan (the original design phase; HANDOFF.md has what was built)

A small WKWebView browser for the iMac's Omarchy-style desktop: AeroSpace tiles it, SketchyBar sits
above it, the chrome borrows the fake notch's style (black, JetBrainsMono Nerd Font Bold, paper text).
Mockups: `mockups/*.png`, rendered by `mockups/render.sh` (SwiftUI + ImageRenderer at 2x, no window).

## Directions

**A. Notch** (`a1`–`a6`) — recommended. No chrome at all except one black pill at the top centre:
lock, host, `3/7`. Hover widens it to back / forward / reload and the full URL; cmd-L turns it into the
palette; cmd-F into find. Timer and now-playing are two more pills at the top right, only while live.
The page is inset 36pt (`WKWebView.obscuredContentInsets`, macOS 26) so its own background runs under
the pills and nothing is ever covered. Tabs are keyboard-only: ctrl-tab held shows the switcher.

**B. Rail** (`b1`–`b4`) — a 44pt black rail of favicons on the left, the active one marked; the timer
ring and the cover at its foot, no text. Hovering it (or cmd-shift-L) widens it to titles, hosts, the
timer's end time and the track. The address is only shown on cmd-L. Always-visible tabs at the cost of
a permanent black column and no URL at rest.

**C. Strip** (`c1`–`c4`) — a 28pt paper strip like a second SketchyBar: tabs on the left in the
workspaces' style (active in ink, others dim), host centred, timer and track on the right; a light
dropdown for the palette. The most literal match to the bar, but tabs and the address share one row,
so it truncates early and stacks two bars when the window is at the top.

Open question on A: with a full-width window the pill sits right under the bar's notch (`a1`). Two
alternatives if that bothers: hang the pill from the window's top edge like a real notch (no gap), or
put it bottom-centre.

## Architecture

Plain `swiftc`, no Xcode project, like the widgets. `build.sh` compiles every `*.swift` in `src/` into
`~/Applications/Casa.app` (bundle id `com.alentodorov.casa`, `CFBundleURLTypes` for http/https so it
can be the default browser, `LSUIElement` false, `codesign -s -`).

| file | what |
|---|---|
| `src/main.swift` | `NSApplication` with `.regular` policy (AeroSpace manages it), delegate, URL-open handling, session restore |
| `src/Keys.swift` | every shortcut in one place, as `NSMenu` key equivalents (a minimal menu bar, which also gives WebKit copy/paste) |
| `src/BrowserWindow.swift` | the widgets' window: `.titled + .fullSizeContentView`, transparent hidden title bar, traffic lights hidden, `canBecomeKey`; minimum 480×320; owns the tabs (one window = one tab group); the pill is the drag area |
| `src/Tab.swift` | a `WKWebView` per tab, shared `WKWebViewConfiguration` (default `WKWebsiteDataStore` → logins persist; private windows get `.nonPersistent()`), KVO for title / url / progress / canGoBack, favicon via `<link rel=icon>` or `/favicon.ico`, `WKDownload` to `~/Downloads`, `isInspectable` |
| `src/Chrome.swift` | the SwiftUI overlay above the web view (pill, status pills, palette, switcher, find); its hosting view only hit-tests its own shapes, `acceptsFirstMouse` true, inset applied to the web view |
| `src/Palette.swift` | one search over open tabs, history (`~/.local/state/casa/history.jsonl`), typed URL or search (DuckDuckGo/Google, configurable), and commands (`>` prefix) |
| `src/Live.swift` | the widget's `mpv()` IPC call against `~/.local/state/yt/mpv.sock` + `tracks.json`, and `~/.local/state/timer/current.json`; polled once a second, hidden when absent |
| `build.sh` | as the widgets' |

No change to the dotfiles or `~/.aerospace.toml` is needed: a regular app's new window appears on the
focused workspace by itself (Chrome needed `open-here.sh` because it pulls focus to existing windows;
Casa makes the window without activating anything else). Optional later: point `alt-shift-enter` at Casa.

## Keyboard map

App shortcuts are pressed with the physical Option key, which arrives as cmd. AeroSpace owns every
`alt-*`, `alt-shift-*`, `alt-cmd-*`, `alt-ctrl-*` and `ctrl-cmd-tab`; Casa binds none of those.
Karabiner's Chrome-only cmd-shift-r rule does not apply; its physical cmd-c/v/x → cmd-c/v/x works here too.

| keys (as the app sees them) | does |
|---|---|
| cmd-L | palette, URL mode (current URL selected) |
| cmd-K | palette, tabs + commands mode |
| cmd-T / cmd-W / cmd-shift-T | new tab / close tab (last one closes the window) / reopen closed |
| cmd-N / cmd-shift-N | new window on this workspace / private window |
| cmd-1…8, cmd-9 | tab N, last tab |
| ctrl-tab / ctrl-shift-tab | next / previous tab; held, the switcher stays open |
| cmd-shift-] / cmd-shift-[ | next / previous tab |
| cmd-[ / cmd-] | back / forward (also two-finger swipe) |
| cmd-R / cmd-shift-R | reload / reload ignoring cache |
| cmd-F, cmd-G, cmd-shift-G, esc | find, next, previous, close |
| cmd-= / cmd-- / cmd-0 | zoom in / out / reset, remembered per host |
| cmd-shift-C | copy URL |
| cmd-shift-D | downloads list |
| cmd-shift-I | Web Inspector |
| cmd-shift-L | (B only) pin the rail open |
| cmd-Q, cmd-C/V/X/A/Z | standard |

## v1

Windows as tab groups, tabs, the pill, palette (tabs, history, URL, search), switcher, back/forward,
reload, find, zoom, downloads to `~/Downloads`, private window, persistent logins, session restore,
timer and now-playing pills, default-browser registration, WebKit's own context menu, Web Inspector.

## Later

Content blocker (`WKContentRuleList` from an EasyList conversion), bookmarks / pinned tabs, moving a
tab between windows, user styles, picture in picture, a `casa` CLI (`casa open URL`, `casa tabs`) for
scripts and SketchyBar, an app icon. No extensions: WebKit has none, so 1Password works only via its
universal autofill, not its extension.

## D. Tiles (added 2026-11-09, built)

`d1`–`d4`: a Casa tab becomes an Omarchy-style workspace that tiles browser and terminal panes with
Hyprland's dwindle layout inside the window. New panes split the focused one along its longer side and
land right or below; cmd-arrows / cmd-shift-arrows / cmd-J / cmd-shift-F / cmd-- cmd-= / cmd-shift-1…9
are Omarchy's keys with physical Cmd as Super. Workspaces 1…5 are always shown in the strip, dimmed
while empty, like Omarchy's persistent workspaces. `mockups/render-tiles.sh` renders the mockups.
