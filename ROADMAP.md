# ClawdBar Roadmap

What's coming next. Tracked here so contributors and curious users can see
where the project is headed.

## Recently shipped

### Daily token spend — landed 2026-09-05

The popover grew a tab bar. **TOKENS** leads: today's spend as a headline, a
7-day or 30-day bar chart under it, and a per-model breakdown — read out of the
transcripts Claude Code already writes to `~/.claude/projects`, so it costs no
API call and no network. **SERVICE** keeps the status panel, which is green
almost every day; it badges itself and steals focus when it isn't.

The scan is incremental (per-file size/mtime/byte cursor) and de-duplicates the
turns that resumed sessions replay — about half of all usage records on a busy
machine — so a refresh is a stat per transcript once the first pass is done.
Cache at `~/.clawdbar/tokens.json`, retention 90 days.

Still open here: the floating overlay has no token page yet — the carousel is
generic over exactly five slots, so adding a sixth is a small refactor. Cost
estimates in dollars are deliberately absent: subscription usage isn't billed
per token, so a dollar figure would be fiction.

### Plan pill reads the account, not the token — landed 2026-09-05

The pill said `PRO` on a Max 5× account. The cause wasn't staleness in
ClawdBar's copy: the OAuth token itself claims `subscriptionType: pro` /
`rateLimitTier: default_claude_ai`, and a token *refresh* keeps whatever the
login minted — so re-running `claude /login` was the only fix, and the API
sends no plan header to cross-check against.

`~/.claude.json` does carry the live answer (`oauthAccount.organizationType`,
`organizationRateLimitTier`), so that is now the primary source, with the token
claims kept as a fallback for setups where the file isn't there.

### Saved credential — landed 2026-09-04

macOS kept asking for the login password because ClawdBar read a keychain item
it does not own. Claude Code rewrites `Claude Code-credentials` on every OAuth
refresh (~5 h), and a rewrite by another process invalidates the per-app ACL
entry that "Always Allow" created — so the next read prompted again.

ClawdBar now mirrors the token into **its own** keychain item
(`com.vinicius.clawdbar.credentials`, `Services/TokenVault.swift`) and reads
that first. It is the only writer of that item, so the authorization survives;
a launch with a live saved token performs zero reads of Claude Code's item. A
mirror is dropped when it expires or when the API answers 401, and Preferences
→ Data Source → Saved credential shows what is stored and deletes it in one
click (`--forget-credential` does the same from the terminal).

The mirror still ages out with the token, so **Use my own token** was added
next to it: paste the output of `claude setup-token` and ClawdBar stops
touching Claude Code's item entirely — no prompt, ever. A 401 on that one is
reported as "re-run setup-token" instead of silently discarding the user's
choice.

Still open here: the ACL is bound to the app's code signature, so an ad-hoc
build re-prompts once after every rebuild. Developer ID signing fixes that for
released builds; a sandboxed/entitled build could move to the data-protection
keychain, which has no ACL prompts at all.

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
  need to re-run `claude /login`, or save a long-lived `claude setup-token`
  token in Preferences → Data Source, which sidesteps the expiry entirely.
  Refreshing the OAuth pair ourselves stays on the wishlist and stays risky:
  if Anthropic rotates refresh tokens on use, ClawdBar would silently sign the
  CLI out. See [CONTRIBUTING.md](./CONTRIBUTING.md#things-on-the-wishlist).
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
