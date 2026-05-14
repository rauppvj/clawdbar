# Homebrew distribution

This folder holds the source-of-truth Cask formula for ClawdBar. The actual
Homebrew tap lives in a separate public repo at **`rauppvj/homebrew-tap`** —
this folder mirrors its layout so updates flow one-way:

```
homebrew/Casks/clawdbar.rb   (this repo, version-controlled with the app)
        │
        │  on release
        ▼
rauppvj/homebrew-tap/Casks/clawdbar.rb   (the public tap)
```

## One-time tap setup

1. Create a **public** GitHub repo named exactly `homebrew-tap` under your
   `rauppvj` account. The `homebrew-` prefix is what makes Homebrew recognize
   it as a tap.
2. Bootstrap it:
   ```bash
   gh repo create rauppvj/homebrew-tap --public \
       --description "Homebrew tap for rauppvj projects" --clone
   cd homebrew-tap
   mkdir -p Casks
   cp /path/to/clawdbar/homebrew/Casks/clawdbar.rb Casks/
   git add Casks/clawdbar.rb
   git commit -m "Add ClawdBar 0.1.0 cask"
   git push origin main
   ```
3. Users can now install:
   ```bash
   brew install --cask rauppvj/tap/clawdbar
   ```
   (Homebrew expands `rauppvj/tap` → `github.com/rauppvj/homebrew-tap`.)

## Release flow per version

When you cut a new ClawdBar release (`git tag v0.2.0 && git push --tags` in
this repo triggers the release workflow that produces the DMG):

1. Wait for the GitHub Release to publish with `ClawdBar-0.2.0.dmg` attached.
2. Compute the new DMG hash:
   ```bash
   shasum -a 256 ClawdBar-0.2.0.dmg
   ```
3. Update `homebrew/Casks/clawdbar.rb` in this repo: bump `version` and
   `sha256`. Commit.
4. Copy the updated file into the `homebrew-tap` repo and push.
5. (Optional) Once you have ≥3 releases and steady usage, automate steps 2–4
   in the release workflow with `brew bump-cask-pr` or a custom script.
