# Scripts

## `bundle.sh`
Builds the release binary, assembles `YACW.app` (ad-hoc signed, `LSUIElement`, SwiftPM resource bundle copied into `Contents/Resources`) and zips it to `dist/yacw-<version>.zip` for a GitHub release.

```
./scripts/bundle.sh                       # version 0.1.0, bundle id local.yacw
VERSION=0.2.0 BUNDLE_ID=com.example.yacw ./scripts/bundle.sh
```
The signature is ad-hoc (no Developer ID, no notarization). The first time, Gatekeeper blocks the app: right click the app > **Open** > **Open**, or run `xattr -dr com.apple.quarantine YACW.app` for a downloaded copy. Binaries are never committed (`*.app` and `dist/` are git-ignored).

## `statusline-writer.py` (source B, optional)
Claude Code runs this script as its `statusLine` command and pipes a JSON document to it. It keeps **only** `rate_limits` and a timestamp, writes them atomically to `~/Library/Application Support/YACW/state.json`, and prints nothing (so it replaces any status line text you had).

Install — back up first, then add to `~/.claude/settings.json`:
```
cp ~/.claude/settings.json ~/.claude/settings.json.bak
```
```json
{ "statusLine": { "type": "command", "command": "/absolute/path/to/yacw/scripts/statusline-writer.py" } }
```
(`chmod +x` the script; merge with your existing settings.) It starts producing data after the next Claude Code response. If you already use a status line, call the writer from your own script instead of replacing it.

Revert: remove the `statusLine` key, or restore the backup:
```
cp ~/.claude/settings.json.bak ~/.claude/settings.json
rm -f ~/Library/Application\ Support/YACW/state.json
```

## `privacy-check.sh`
Scans tracked files (and with `--history` every commit) for credentials, e-mail addresses, home paths and organization ids; prints locations, never values. Extra personal terms can go in a git-ignored `.privacy-terms` file. CI runs it.
