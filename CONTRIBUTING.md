# Contributing

Thanks for the interest. ClawdBar is a small, focused tool — contributions that
keep it small and focused are very welcome. Larger changes work better as a
discussion in an issue first.

## Local dev

```bash
swift build               # debug build
swift test                # all unit tests (parser, daemon mocks, settings persistence)
swift run ClawdBar        # run the app from a terminal
swift run ClawdBar --probe-credentials
swift run ClawdBar --probe-api
```

Or open `Package.swift` directly in Xcode for full IDE workflow (build, run,
Instruments, etc.).

## Code style

- **No third-party dependencies** unless there's a specific reason a built-in
  Apple framework can't do the job. Justify the dep in your PR description.
- **Services stay UI-free.** `Services/CredentialStore`, `UsageDaemon`, and
  `AnthropicAPIClient` should be runnable from a CLI or a future Linux daemon
  with no SwiftUI imports.
- **Tests for parsers and state machines.** UI tests are out of scope for now.
- **Strict concurrency.** Swift 6 mode is on. Treat warnings as errors before
  opening a PR.

## Architecture cheatsheet

```
UsageDaemon          ← @Observable @MainActor; orchestrates polling
  ├─ CredentialStore (Keychain → legacy file fallback)
  └─ AnthropicAPIClient (URLSession, 1-token Haiku ping, header parsing)

NotificationManager  ← UNUserNotificationCenter wrapper, threshold transitions
AppSettings          ← UserDefaults-backed @Observable settings model
LaunchAtLogin        ← SMAppService wrapper

Views/
  MenuBarLabelView   ← reads daemon.usage + settings.menuBarStyle
  Popover/           ← dark-theme popover (PopoverView, StatusRowView, UsageBarView)
  Overlay/           ← floating NSPanel + SwiftUI content
  Settings/          ← multi-tab Preferences scene
  Onboarding/        ← first-run flow
  Mascot/            ← procedural pixel mascot (Canvas paths, no PNGs)
```

## Things on the wishlist

| Idea | Why | Sketch |
|---|---|---|
| OAuth refresh-token flow | Today users have to re-run `claude /login` after ~5h. Wire up the Anthropic refresh-token endpoint and write the new pair back to keychain via `SecItemUpdate`. | Confirm the endpoint URL + payload from the Claude Code source or community docs first — we don't want to corrupt the stored credential. |
| Anthropic API key support | Today only the Claude Code OAuth path is wired up (Pro / Max / Max 20× / Team). API-direct users (api keys from console.anthropic.com) can't use ClawdBar yet. | Add a second `CredentialSource.apiKey(String)` case; auth via `x-api-key` instead of `Authorization: Bearer`; parse the different header family (`anthropic-ratelimit-requests-*`, `anthropic-ratelimit-tokens-*`, `anthropic-ratelimit-input-tokens-*`, `anthropic-ratelimit-output-tokens-*`); add a settings panel for the key (secure text field, store in Keychain under a ClawdBar-owned item); add a `UsageData.kind` enum so the popover can render either 5h/7d windows OR rolling RPM/TPM gauges. |
| Final mascot art | Today's procedural pixel mascot (`Views/Mascot/MascotView.swift`, Canvas paths, mood-driven eyes/mouth) is a placeholder while the owner finishes design studies. | Either keep the Canvas approach and rewrite the cell layout, or switch to a sprite-sheet asset rendered into `MascotImage.render(...)`. Preserve the `UsageData.Mood` enum so other features that read it (menu bar icon, status dot, overlay) still work. |
| Tamagotchi page (4th carousel slide) | Animated mascot doing idle stuff in its own page of the floating overlay — blinking, hopping, snacking, reacting to usage spikes. | Add `Views/Overlay/TamagotchiPage.swift`; use `TimelineView` to drive multi-frame sprite animation; wire as page 3 in `OverlayCarousel`. Coordinate with the mascot redesign so they share assets. |
| Cross-platform builds — Linux + Windows | macOS-only today. The `Services/` layer is already UI-free; the daemon + parser logic could power non-Apple tray icons. | Extract `Services/` into its own SPM library product. Linux: Swift on Linux + GTK status icon (or AppIndicator), `libsecret`/`gnome-keyring` for credentials. Windows: easiest is to rewrite the daemon in C#/F# and share only the algorithm + header parser. First viable shipment: a CLI that prints utilization, then per-platform tray icons. |
| Multi-provider support (OpenAI Codex, DeepSeek, Cursor, …) | Today the entire auth + parser + UI stack is Anthropic-specific. To track usage from other AI assistants users run in parallel, introduce a provider abstraction. | Define `UsageProvider` protocol (`name`, `icon`, `fetch(credentials:) → [UsageWindow]`). Generalize `UsageData` to `[UsageWindow]` (each window: title, percent, reset, severity). Add a Settings tab to manage providers (toggle which ones to poll). Decide: aggregated single popover showing all providers stacked, vs per-provider tabs. Each new provider needs credential discovery (Keychain item / config file / pasted API key), API client, header parser. **Not a priority** — Anthropic-only v0.1 is intentionally complete on its own. Owner will bump priority later if the user audience expands. |
| Native Spotify integration | Embed a mini Spotify playback control (current track + play/pause/skip) inside ClawdBar so users don't context-switch between apps to manage music. | Two paths: AppleScript bridge (`tell application "Spotify"`) for local control on macOS, or Spotify Web API for remote control across devices. **Lowest priority** — this is a nice-to-have, not part of the core "usage dashboard" identity. |
| Sparkline history view | Visual trend of last N hours in the popover. | Append-only JSONL at `~/.clawdbar/history.jsonl`, parse in a `HistoryStore`, draw with SwiftUI Charts. |
| Multi-account | Some users have a Max plan plus an API console org. | Multi-keychain-item discovery, account picker in settings, separate poll cycles. |
| Linux daemon | The same `UsageDaemon` could power a tray icon on Linux. | Extract `Services/` into its own SPM library product; build a small CLI consumer; replace Keychain with `libsecret` or a CLI prompt for a token file. |
| Windows menu-bar port | Same idea via WinUI 3 / system tray. | Port `UsageDaemon` logic to C# / F#; share only the algorithm and the API protocol. |
| ESP32 hardware bridge | Forward parsed UsageData to a custom ESP32 desk display over USB-serial / Bluetooth. | Add a `Services/ESP32Bridge.swift` that publishes a compact binary frame format any ESP32 firmware could consume. |
| Cache Components / Vercel-style PPR | Out of scope — no server. |  |

## Reporting bugs

Please include:

- ClawdBar version and macOS version
- Output of `.build/release/ClawdBar --probe-credentials` (it's safe — values
  are replaced with `present (N chars)`)
- Output of `.build/release/ClawdBar --probe-api` if the issue is data-related
- Whatever the popover's footer error tag says (`AUTH`, `RATE`, `OFFLINE`, …)

## Auditing the codebase

You don't have to trust the privacy claims in the README. From the repo root:

```bash
# 1. Zero third-party Swift dependencies (only the test target → main target):
grep -E "dependencies|\.package" Package.swift

# 2. Every network endpoint baked into the source:
grep -rn -E 'URL\(string:|"https?://' Sources/

# 3. Every framework imported (all Apple-shipped):
grep -hE "^import " Sources/ClawdBar/**/*.swift | sort -u

# 4. Every non-text file bundled:
find Sources/ClawdBar/Resources -type f -exec file {} \;
```

At time of writing the only remote endpoint is `api.anthropic.com` (configurable
in Preferences for dev use). The only bundled binary asset is
`PressStart2P-Regular.ttf` — pulled from the official
[github.com/google/fonts](https://github.com/google/fonts/tree/main/ofl/pressstart2p)
mirror, SIL OFL licensed, digitally signed by the Press Start 2P Project Authors.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Menu bar shows ⚠ icon, popover says "Not signed in" | Keychain item missing | Run `claude /login` in a terminal |
| 401 errors in the popover footer | OAuth token rotated / expired | Re-run `claude /login` |
| Keychain prompt fires on every poll | You hit "Allow" instead of "Always Allow" | Open Keychain Access → search "Claude Code-credentials" → Access Control → drop ClawdBar in the always-allow list |
| Keychain prompt fires on every **rebuild**, not every poll | Unsigned binary — each `swift build` produces a new CDHash, and the macOS "Always Allow" ACL is bound to that exact hash | See **Stopping the keychain re-prompt loop in dev** below |
| 429 errors | You actually hit your rate limit | Wait for the reset shown in the popover |
| Floating window invisible on a fullscreen app | A different app is using `.statusBar` window level | Try `OverlaySettings.level = .statusBar` (planned setting) |
| "ClawdBar is damaged and can't be opened" on first launch | Email/Slack/Drive stripped extended attributes from an ad-hoc-signed bundle | `xattr -dr com.apple.quarantine /Applications/ClawdBar.app` |

## Stopping the keychain re-prompt loop in dev

If macOS keeps asking you to authorize ClawdBar every time you rebuild, that's
expected for an unsigned binary — the "Always Allow" decision is bound to the
binary's CDHash, and that hash changes every `swift build`. Three levels of fix:

### 1. Runtime cache (already enabled)

`UsageDaemon` caches the OAuth token in memory after the first read. You'll see
**at most one prompt per app launch** instead of one per poll. The cache is
invalidated automatically on 401 and via the "Re-read credentials" button in
**Preferences → Data Source**.

If you only see one prompt per launch, you're already done.

### 2. Persistent dev signing identity (one-time setup)

To eliminate prompts entirely *across rebuilds*, sign the binary with a
self-signed certificate whose identity stays the same between builds:

```bash
# Create a Code Signing certificate in your login keychain (one-time):
#   Keychain Access → Certificate Assistant → Create a Certificate…
#   Name: "ClawdBar Dev"
#   Identity Type: Self Signed Root
#   Certificate Type: Code Signing

# Then after each build:
codesign --force --sign "ClawdBar Dev" .build/arm64-apple-macosx/debug/ClawdBar
```

The Keychain ACL stores the certificate identity rather than the binary hash,
so rebuilds with the same identity skip the prompt.

### 3. Apple Developer ID + notarization (for distribution)

For a build you ship to other people, see **Migrating to a signed Xcode
project** below. That gives you a `.app` bundle signed with your team's
Developer ID Application certificate and notarized through Apple — no prompts,
no Gatekeeper warnings, no surprise dialogs on first launch.

## Migrating to a signed Xcode project

ClawdBar ships as a Swift Package, which is fine for development but doesn't
expose the entitlements editor, code-signing identity picker, or notarization
flow you'll want before shipping. To convert:

1. `File → New → Project` in Xcode → **macOS → App** template.
2. Set product name `ClawdBar`, bundle ID `com.vinicius.clawdbar`, deployment
   target macOS 15. Uncheck "Use Core Data" / tests / etc. — keep it minimal.
3. Drag the contents of `Sources/ClawdBar/` into the new app target. In the
   "Choose options" sheet, **un-check** "Copy items if needed" so the files
   stay in this repo — or do copy them if you want a clean split.
4. Drag `Sources/ClawdBar/Resources/` into the project too. Set Localizable
   .strings files to localize for `en` and `pt-BR`.
5. Add the keychain entitlement: `Target → Signing & Capabilities → + Capability →
   Keychain Sharing` (no shared group needed; the entitlement alone is what
   lets the sandbox read login.keychain items).
6. Set `LSUIElement = YES` in Info.plist so the app stays out of the Dock.
7. Pick your Apple Developer team and set "Hardened Runtime" on. Notarize via
   `xcrun notarytool` once the Archive succeeds.

`.github/workflows/ci.yml` includes a stub release job (disabled with `if: false`)
that lays out where the signing + notarization steps go in CI.
