# ClawdBar for Windows

> Native Windows tray app that shows your live Claude Code usage at a glance.

A port of ClawdBar to Windows (C#, WinForms + GDI+), living alongside the macOS/SwiftUI
app in the same repo. Same idea, same design language, same 5 h / 7 d numbers — rebuilt
around the notification area instead of the macOS menu bar.

Everything here is self-contained under `windows/`. It shares no build with the Swift
package and the macOS CI workflow is untouched.

ClawdBar polls Anthropic's Messages API with a 1-token Haiku ping, parses the
`anthropic-ratelimit-unified-*` headers, and surfaces your **5 h session** and **7 d weekly**
utilization in the tray — plus a floating overlay, threshold notifications, and a 7-day
activity heatmap.

| | |
|---|---|
| ![Tray panel](docs/popup.png) | ![Floating overlay](docs/overlay-usage.png) |
| The tray panel | The floating widget |

## Requirements

- **Windows 10 or 11**
- **.NET Framework 4.x** — preinstalled on every supported Windows; nothing to download
- An active **Claude Code** login — run `claude /login` first

No .NET SDK, no NuGet, no Visual Studio. The app builds with the C# compiler that already
ships inside Windows and runs as a single self-contained `.exe` (font and icon embedded).

## Build

```cmd
build.cmd
```

That's it — output lands in `dist\ClawdBar.exe` (~260 KB). Double-click it, or run it from
a terminal. Look for the capybara in your notification area; Windows may tuck it into the
overflow ("^") on first run, so drag it onto the taskbar if you want it always visible.

## How it works

Claude Code on Windows stores its OAuth token at:

```
%USERPROFILE%\.claude\.credentials.json
```

ClawdBar reads that file directly — no permission prompt, because it is a file in your own
profile. If it is missing, Windows Credential Manager is checked for a generic credential
named `Claude Code-credentials` as a fallback.

It then calls the Messages API with the cheapest Haiku model and `max_tokens: 1`, and parses:

```
anthropic-ratelimit-unified-5h-utilization
anthropic-ratelimit-unified-5h-reset
anthropic-ratelimit-unified-7d-utilization
anthropic-ratelimit-unified-7d-reset
anthropic-ratelimit-unified-representative-claim
```

At the default 60-second interval each day costs roughly 1.4 k Haiku tokens — on the order
of **US$ 0.0001/day** against your Anthropic account.

### Supported plans

The unified 5 h + 7 d rate-limit system is the same across every Claude Code plan, so this
works on **Pro**, **Max** (5× and 20×) and **Team**. The plan badge in the panel comes
straight from the token's `subscriptionType`.

**Not supported:** direct Anthropic API keys from console.anthropic.com — different auth
scheme (`x-api-key`) and a different rate-limit header family.

## What's in it

- **Tray icon**, five styles: Numeric, Mini Bar, Mascot, Dual Bar, Hybrid
- **Panel** on left-click — both windows, reset countdowns, plan badge, which window is
  currently binding, refresh / overlay / preferences / quit
- **Floating widget** with four pages you page through with the chevrons:
  current usage, activity heatmap, stats, and the tamagotchi where the capybara slowly
  drowns as you burn through your window
- **Preferences**: poll interval, launch at login, icon style, overlay opacity /
  click-through / snap corner / size lock, notification thresholds, API host and model
- **Threshold alerts** as tray notifications, with separate latches for 5 h and 7 d
- **Local history** at `%USERPROFILE%\.clawdbar\history.jsonl`, same JSON-Lines format as
  the macOS build — copy one across and your streaks come with it

| | | |
|---|---|---|
| ![Heatmap](docs/overlay-heatmap.png) | ![Stats](docs/overlay-stats.png) | ![Tamagotchi](docs/overlay-tamagotchi.png) |

## CLI probes

```cmd
ClawdBar.exe --probe-credentials   :: inspect stored credentials (shape only, never the token)
ClawdBar.exe --probe-api           :: spend 1 Haiku token, dump every anthropic-* header
ClawdBar.exe --reset-onboarding    :: delete the settings file
ClawdBar.exe --help
```

These attach to the calling console. Redirect to a file if you launch them from something
other than a terminal.

## What changed from the macOS original

Ports are where the interesting decisions live. The behaviour differences, all deliberate:

| macOS | Windows | Why |
|---|---|---|
| Keychain via `SecItemCopyMatching`, with an approval prompt | `.credentials.json` read directly | That is where Claude Code puts the token on Windows. No prompt exists to walk the user through, so onboarding lost that step. |
| Wide menu-bar label (`S:12% W:34%`) | Square tray icon, numbers in the tooltip | A tray slot is square. Every style was re-laid out to fit; the full text moved to the tooltip. |
| Menu-bar mascot auto-tints (template image) | Mascot drawn in full colour | Windows has no template-image tinting. The tan body reads against both light and dark taskbars. |
| `SMAppService` login item | `HKCU\...\CurrentVersion\Run` value | The per-user, no-elevation equivalent. Moving the .exe breaks it — re-toggle after moving. |
| `UNUserNotificationCenter`, permission request | Tray balloon notifications | Real toasts without registering an AppUserModelID, which keeps the app a single portable .exe. No permission step needed. |
| Low Power Mode → 5× backoff | Battery saver → 5× backoff | Closest equivalent signal. |
| Sliders in Preferences | Numeric spinners | Sliders can't be themed dark in WinForms without owner-drawing every part; the per-row "reset to default" buttons survive. |
| `UserDefaults` | `%APPDATA%\ClawdBar\settings.json` | Same key names, so the two are easy to diff. |
| `--export-icon` | *not ported* | It generated macOS `.icns` asset sizes. The Windows `.ico` is committed in `res\`. |

Two things were fixed rather than carried over:

- **"Show mascot" was a dead toggle** in the original — written to preferences, never read.
  Here it actually hides the capybara on the tamagotchi page.
- **Double-clicking the overlay's "next" arrow** advanced only one page, because the second
  click arrives as `WM_LBUTTONDBLCLK` and never reaches the click handler.

## Privacy

- The OAuth token is read locally and only ever sent to the configured API host.
- No telemetry, no analytics, no crash reporting.
- Usage history stays on disk at `%USERPROFILE%\.clawdbar\history.jsonl`.
- `--probe-credentials` prints token **length and an 8-character prefix**, never the token.

## Uninstall

1. Quit from the tray menu.
2. Delete `dist\ClawdBar.exe` (or the whole folder).
3. Optional cleanup:

```cmd
rmdir /s /q "%APPDATA%\ClawdBar"
rmdir /s /q "%USERPROFILE%\.clawdbar"
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v ClawdBar /f
```

The last line is only needed if you enabled "Launch at login".

## Layout

```
src\          the app (one namespace, no project file)
  Json.cs             hand-rolled JSON reader/writer — no package feed to pull from
  Models.cs           UsageData, Credentials, samples, derived stats
  AppSettings.cs      JSON-backed preferences
  Services.cs         credential store, API client, history, login item, notifications
  UsageDaemon.cs      poll loop, credential cache, sleep/wake
  Theme.cs            palette, embedded font, shared GDI+ drawing
  Mascot.cs           the 16x16 procedural capybara
  TrayIconRenderer.cs tray bitmaps for the five styles
  PopupForm.cs        the tray panel
  OverlayForm.cs      the floating widget and its four pages
  SettingsForm.cs     preferences
  OnboardingForm.cs   first run
  Program.cs          entry point, CLI probes, tray context
tools\Preview.cs      dev harness: opens one window standalone for inspection
res\                  Press Start 2P (SIL OFL) + the app icon
build.cmd             builds the app
build-preview.cmd     builds the dev harness
```

### Dev harness

```cmd
build-preview.cmd
dist\Preview.exe popup       :: or: settings, onboarding
```

Opens a single window against live data, without going through the tray. Quit ClawdBar
first so the two aren't both polling.

## License

MIT, same as the rest of the project — see [LICENSE](../LICENSE). Press Start 2P retains
its SIL OFL license; see `res\OFL.txt`.

**Unofficial. Not affiliated with Anthropic.**
