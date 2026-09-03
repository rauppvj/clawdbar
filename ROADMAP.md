# ClawdBar Roadmap

What's coming next. Tracked here so contributors and curious users can see
where the project is headed.

## Recently shipped

### Service status — landed 2026-09-03

ClawdBar now mirrors [status.claude.com](https://status.claude.com): the overall
indicator, a dot per component, and any unresolved incident. It shows up as a
section in the popover and as a fifth page on the floating overlay, and both
open the full page on click.

It polls the public `api/v2/summary.json` every 2 minutes on its own cadence —
unauthenticated, no usage data, no tokens spent — so a failing request can be
told apart from your own rate limit. **Preferences → Data Source → Service
status** turns it off, and off means zero traffic to that host.

Still open here: turning a status change into a notification, which is the
obvious next step now that the monitor knows when the worst level moves.

### Windows port — landed 2026-08-26

ClawdBar now runs on Windows. The port lives in [`windows/`](./windows) and was
contributed by [@KewinSantos](https://github.com/KewinSantos) in PR #1.

It is a native rewrite in C# on WinForms + GDI+ rather than shared Swift code —
tray icon, panel, floating overlay, heatmap and tamagotchi, same palette and
same Press Start 2P typeface. It builds with the C# compiler that already ships
inside Windows, so there is no SDK or package feed to install:

```cmd
cd windows
build.cmd
```

History at `~/.clawdbar/history.jsonl` uses the identical JSON-Lines format on
both platforms, so a history file moves between them and streaks survive.
Platform differences and the reasoning behind each are documented in
[windows/README.md](./windows/README.md).

Still open on Windows: attaching the built `.exe` to releases (CI produces it as
a workflow artifact today) and the SmartScreen note for unsigned builds.

## Medium-term — broadens the product

### Linux build

With Windows shipped, Linux is what remains of the cross-platform goal. The
`Services/` layer is already SwiftUI-free, so extracting it as a separate SPM
library product to power a non-Apple tray icon is feasible: Swift on Linux + a
GTK status icon (or AppIndicator), replacing Keychain with `libsecret` /
`gnome-keyring` or a token file.

**Minimum viable path**: ship a CLI that prints utilization numbers first —
Linux daemons can consume that — then add a tray icon.

Worth noting: the Windows port chose a full native rewrite over sharing Swift
code, and that worked out well. Sharing only the algorithm and the rate-limit
header parser is a legitimate strategy here too.

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
- **Signing.** macOS builds are ad-hoc signed; first launch needs right-click
  → Open. Apple Developer ID + notarization will land when the project
  graduates from dev preview. The Windows `.exe` is unsigned too, so
  SmartScreen shows a warning — "More info" → "Run anyway".

---

Have ideas? Open an issue. PRs welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md).
