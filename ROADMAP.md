# ClawdBar Roadmap

What's coming next. Tracked here so contributors and curious users can see
where the project is headed.

## Medium-term — broadens the product

### Cross-platform builds — Linux + Windows

Today everything is Apple-framework based. The `Services/` layer is already
SwiftUI-free, so extracting it as a separate SPM library product to power
non-Apple tray icons is feasible.

- **Linux**: Swift on Linux + GTK status icon (or AppIndicator). Replace
  Keychain with `libsecret` / `gnome-keyring` lookup or a token file.
- **Windows**: Swift on Windows is still rough — likely easier to rewrite
  the daemon in C# / F#, sharing only the algorithm + header parser.
- **Minimum viable path**: ship a CLI that prints utilization numbers first
  (Linux daemons can consume that), then add a tray icon per platform.

### DANCE manual state + accessories for the mascot

The 4 automatic animation states (sleep / chill / work / panic) shipped in
v0.1. DANCE is reserved as a manual toggle — likely via the floating
overlay context menu — that swaps in a 4-key body bounce at 0.45 s, ears
wiggling out of phase, and music-note accessories floating up. Also
pending: Z accessories during sleep, sweat-drop accessories during panic.

## Longer-term — adjacent territory

These expand the product into nearby spaces. The Anthropic-only v0.1 is
already a complete, shippable experience on its own.

### Multi-provider support — OpenAI Codex, DeepSeek, Cursor, etc.

The current stack (Keychain lookup, `AnthropicAPIClient`, `UsageData`,
popover labels, heatmap) is Anthropic-only. Many users run multiple AI
assistants in parallel and would benefit from one menu-bar widget covering
all of them.

Strategy: introduce a `UsageProvider` protocol (`name`, `icon`,
`fetch(credentials:) → [UsageWindow]`) and generalize `UsageData` from
hard-coded `sessionPercent + weeklyPercent` into a list of `UsageWindow`
values. Each provider supplies its own credential discovery (Keychain item
/ config file / pasted API key) and header parser. Open design choices:
aggregated single-popover view vs per-provider tabs; how to pick the
"dominant binding" window across mixed providers; polling interval.

### Native Spotify playback control

Embed a mini player in the popover or overlay so the user doesn't
context-switch out to manage music. Two paths to consider: an AppleScript
bridge (`tell application "Spotify"`) for local control on macOS, or the
Spotify Web API for remote control across devices. Lowest priority — a
nice-to-have, not part of the core usage-dashboard identity.

## Known limitations

- **Token refresh.** Claude Code OAuth tokens have a ~5 h life. On 401 you
  need to re-run `claude /login`. Automatic refresh against the Anthropic
  OAuth endpoint is on the wishlist; see [CONTRIBUTING.md](./CONTRIBUTING.md#things-on-the-wishlist).
- **API-direct support.** Today only the Claude Code OAuth path is wired
  (Pro / Max / Team). Anthropic API keys from console.anthropic.com use a
  different auth scheme (`x-api-key`) and a different rate-limit header
  family — needs its own adapter.
- **Signing.** Builds are ad-hoc signed; first launch needs right-click →
  Open. Apple Developer ID + notarization will land when the project
  graduates from dev preview.

---

Have ideas? Open an issue. PRs welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md).
