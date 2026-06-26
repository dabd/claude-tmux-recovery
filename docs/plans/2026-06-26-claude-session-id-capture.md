# Claude Session-ID Capture for tmux Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## As-built status (2026-06-26)

**Task 1 (capture) is DONE, delivered as a Claude Code plugin, not manual settings.json edits.** The plan below predates that decision; prefer this note where they conflict.

- The capture half ships as the `tmux-session-recovery` plugin in this repo (`plugins/tmux-session-recovery/`): a `SessionStart` hook in `hooks/hooks.json` runs `scripts/record-tmux-session.sh`. Installed via `claude plugin install tmux-session-recovery@claude-tmux-recovery`. Verified live: a real session logged its id, and the id resolves to a resumable `.jsonl`.
- **Superseded specifics:** the plan's manual registration in `~/.claude/settings.json` and the script at `~/.config/claude-hooks/record-tmux-session.sh` are NOT how it was built (both were backed out). The plugin carries the hook, so there is no per-machine settings.json edit. The script lives in the plugin at `plugins/tmux-session-recovery/scripts/`.
- **Still correct from the plan below:** the record-at-birth architecture, positional keys, reading `session_id`/`cwd` from stdin, verbatim cwd, and the no-op-outside-tmux guard. The script honors `TMUX_CLAUDE_LOG` to override the log path.
- **`CLAUDE_CONFIG_DIR`:** enable the plugin in each config dir (work `~/.claude` and personal `~/.claude-personal`) separately; config dirs are isolated.

**Task 2 (recovery: resurrect sidecar + reader) is DONE**, and it does NOT depend on the dotfiles tmux port (that earlier claim was wrong). Both scripts live in the plugin: `scripts/tmux-claude-snapshot.sh` (the resurrect `post-save-all` hook) and `scripts/tmux-claude-recover.sh` (the reader). The only tmux-config piece is one `@resurrect-hook-post-save-all` line, wired into the live `~/.tmux.conf` now and portable to the managed `tmux/tmux.conf` later. Verified against the running server: a real resurrect save wrote 26 panes to the sidecar; the reader mapped each to the correct `claude --resume <id>`.

**Two bugs found and fixed during the build (do not regress):**
- tmux format strings do NOT expand `\t`; it stays a literal backslash-t. The scripts build the format with real tab bytes via `$'\t'`. The inline-one-liner README version was wrong.
- resurrect's `execute_hook` runs the hook value with `eval` in a plain shell, NOT via tmux. So the hook value must be a plain shell command (the script path), not `run-shell "..."`.

**Goal:** Automatically record which Claude Code session id runs in each tmux pane, so that after an unexpected tmux restart every restored window knows exactly which session to `claude --resume`, even when many sessions share one working directory.

**Architecture:** Record at *birth*, not at death. A tmux hook cannot read a dead pane's environment (the hook runs in the server, the env died with the pane), and a shell trap will not fire on SIGKILL, so capturing "when a session gets killed" is unreliable. Instead a Claude Code `SessionStart` hook fires when a session starts or resumes and (a) stamps the live session id onto the pane as a tmux user option `@claude_session_id`, and (b) appends an immutable row to a persistent log keyed by pane *position*. A tmux-resurrect `post-save-all` hook snapshots all panes' positions + ids to a sidecar aligned with each resurrect save. After a restart, a recovery reader matches restored panes to ids by position.

**Tech Stack:** Claude Code `SessionStart` hook (`~/.claude/settings.json` + a hook script), tmux user options + `display-message`, tmux-resurrect `@resurrect-hook-post-save-all`, a bash recovery reader.

## Global Constraints

- Why positional keys: `$TMUX_PANE` (e.g. `%40`) is unique only within a live server and is reassigned after a restart. The durable key across a resurrect save+restore is `(session_name, window_index, pane_index)`, which resurrect restores; `window_name` is a tiebreak. `renumber-windows on` shifts indices as windows close, so recovery reads the *newest* row per id and treats position as a hint plus `window_name` as tiebreak.
- The session id is read from the hook's **stdin JSON `session_id` field** (the documented source). There is no `CLAUDE_CODE_SESSION_ID` exported to hook processes.
- Store `cwd` **verbatim** from the hook's stdin JSON. Do NOT reconstruct the Claude projects slug: Claude replaces both `/` and `.` with `-` (`/Users/.../dotfiles` -> `-Users-dario-abdulrehman-dotfiles`), so naive slugging is wrong.
- `~/.claude/settings.json` already has a `hooks.PreToolUse` entry (the prose normalizer). ADD `SessionStart`; do not remove or overwrite existing hooks.
- The hook must be a no-op when not inside tmux (`$TMUX_PANE` unset) and must never fail the session start: exit 0 always, guard every tmux call.
- Hook script lives at `~/.config/claude-hooks/record-tmux-session.sh` (machine-local, outside the dotfiles repo for now; it references the user's home layout). The resurrect-hook line is the only piece that lands in the repo's `tmux/tmux.conf`.
- This plan depends on the tmux port plan (`2026-06-26-tmux-port.md`) for the managed `tmux/tmux.conf`. Land that first; Task 2 Step 1 edits that file.

## File Structure

- `~/.config/claude-hooks/record-tmux-session.sh` - the SessionStart hook: stamps `@claude_session_id` on the pane and appends a positional row to the log. (Machine-local.)
- `~/.claude/settings.json` - register the `SessionStart` hook (merge into existing `hooks`).
- `~/.local/share/tmux/claude-sessions.log` - persistent append log, survives hard crash. (Runtime data, not committed.)
- `~/.local/share/tmux/resurrect/claude-ids.last` - positional sidecar written at each resurrect save. (Runtime data.)
- `tmux/tmux.conf` (in repo) - add one `@resurrect-hook-post-save-all` line.
- `~/.config/tmux/scripts/tmux-claude-recover.sh` - recovery reader; symlinked via the repo's `tmux/scripts/` (so it is reproducible). Lives at `tmux/scripts/tmux-claude-recover.sh` in the repo.

---

## Task 1: SessionStart hook records pane -> session-id

**Files:**
- Create: `~/.config/claude-hooks/record-tmux-session.sh`
- Modify: `~/.claude/settings.json` (add `SessionStart` under `hooks`)

**Interfaces:**
- Produces: each live pane carries tmux option `@claude_session_id`; one row per start/resume appended to `~/.local/share/tmux/claude-sessions.log` in the format:
  `ISO8601\tsession_id\ttmux_session_name\twindow_index\tpane_index\twindow_name\tcwd`

- [ ] **Step 1: Write the hook script**

Create `~/.config/claude-hooks/record-tmux-session.sh`:

```bash
#!/usr/bin/env bash
# Claude Code SessionStart hook. Records which Claude session id is running in
# the current tmux pane, for recovery after a tmux restart. No-op outside tmux.
# Never fails the session start: always exits 0.
set -uo pipefail

input="$(cat)"   # stdin JSON from Claude Code

# Session id is the documented stdin field; cwd stored verbatim (do not slug it).
sid="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)"
cwd="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null)"

# Outside tmux, or no id: nothing to record.
[ -n "${TMUX_PANE:-}" ] || exit 0
[ -n "$sid" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Stamp the live pane (server-queryable binding).
tmux set -p -t "$TMUX_PANE" @claude_session_id "$sid" 2>/dev/null || true

# Append an immutable positional row (survives a hard crash with no resurrect save).
pos="$(tmux display-message -p -t "$TMUX_PANE" \
  '#{session_name}'$'\t''#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}' 2>/dev/null)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log="$HOME/.local/share/tmux/claude-sessions.log"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\n' "$ts" "$sid" "$pos" "$cwd" >> "$log"

exit 0
```

Then make it executable:
```bash
chmod +x ~/.config/claude-hooks/record-tmux-session.sh
```

- [ ] **Step 2: Manually verify the script with a synthetic stdin (no Claude needed)**

Run from inside a tmux pane:
```bash
echo '{"session_id":"test-uuid-1234","cwd":"/tmp","hook_event_name":"SessionStart","source":"startup"}' \
  | ~/.config/claude-hooks/record-tmux-session.sh
echo "exit: $?"
tmux show -p @claude_session_id
tail -1 ~/.local/share/tmux/claude-sessions.log
```
Expected: exit `0`; `@claude_session_id test-uuid-1234` printed; the log's last row contains `test-uuid-1234`, the current session/window/pane, and `/tmp`.

- [ ] **Step 3: Verify the no-op-outside-tmux guard**

Run:
```bash
env -u TMUX -u TMUX_PANE bash -c 'echo "{\"session_id\":\"x\",\"cwd\":\"/tmp\"}" | ~/.config/claude-hooks/record-tmux-session.sh; echo exit:$?'
```
Expected: `exit:0` and no new log row (it returned before logging because `$TMUX_PANE` was unset).

- [ ] **Step 4: Register the SessionStart hook in settings.json (merge, do not overwrite)**

Use a JSON-aware merge so the existing `PreToolUse` hook is preserved:
```bash
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p))
hooks = d.setdefault("hooks", {})
entry = {
  "matcher": "*",
  "hooks": [{"type": "command", "command": os.path.expanduser("~/.config/claude-hooks/record-tmux-session.sh")}]
}
ss = hooks.setdefault("SessionStart", [])
# avoid duplicate registration on re-run
if not any(h.get("command","").endswith("record-tmux-session.sh")
           for e in ss for h in e.get("hooks", [])):
    ss.append(entry)
json.dump(d, open(p, "w"), indent=2)
print("SessionStart hooks now:", json.dumps(hooks["SessionStart"], indent=2))
PY
```
Expected: prints the `SessionStart` array containing the `record-tmux-session.sh` command; `matcher: "*"` fires on startup, resume, clear, and compact.

- [ ] **Step 5: Verify settings.json is still valid and PreToolUse survived**

Run:
```bash
python3 -c 'import json; d=json.load(open("'"$HOME"'/.claude/settings.json")); print("hooks keys:", list(d["hooks"].keys()))'
```
Expected: `hooks keys: ['PreToolUse', 'SessionStart']` (both present).

- [ ] **Step 6: Live end-to-end check - start a real Claude session in a fresh pane**

Open a new tmux window, run `claude` (or any quick `claude -p "hi"` invocation), then:
```bash
tail -2 ~/.local/share/tmux/claude-sessions.log
```
Expected: a row whose `session_id` matches a real file under `~/.claude/projects/.../<id>.jsonl`, with the new window's position and cwd. This confirms the hook fires for a genuine session.

- [ ] **Step 7: Commit the recovery reader scaffold note (settings + hook are machine-local; nothing to commit yet)**

No repo commit in this task (the hook script and settings.json are machine-local). Recovery reader is committed in Task 2.

---

## Task 2: Resurrect sidecar + recovery reader (positional id matching)

**Files:**
- Modify: `tmux/tmux.conf` (in the dotfiles repo) - add the resurrect post-save hook line.
- Create: `tmux/scripts/tmux-claude-recover.sh` (in the repo; symlinked to `~/.config/tmux/scripts/` by the existing `xdg.configFile."tmux/scripts"` block).

**Interfaces:**
- Consumes: `@claude_session_id` set on panes by Task 1; the resurrect save event.
- Produces: `~/.local/share/tmux/resurrect/claude-ids.last` (positional sidecar, columns `session_name\twindow_index\tpane_index\twindow_name\tsession_id`); `tmux-claude-recover.sh` prints, per current pane, the `claude --resume <id>` it should run.

- [ ] **Step 1: Add the resurrect post-save-all hook to `tmux/tmux.conf`**

In the dotfiles repo, in the `##### tmux-resurrect / continuum #####` block of `tmux/tmux.conf`, add:

```tmux
# At each resurrect save, snapshot pane position -> Claude session id alongside
# the resurrect save, so a restored pane can find which session it was running.
set -g @resurrect-hook-post-save-all 'tmux list-panes -a -F "#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}\t#{@claude_session_id}" | grep -v "\t$" > ~/.local/share/tmux/resurrect/claude-ids.last'
```

(The `grep -v` drops panes with no `@claude_session_id`, i.e. non-Claude panes.)

- [ ] **Step 2: Write the recovery reader**

Create `tmux/scripts/tmux-claude-recover.sh` in the repo:

```bash
#!/usr/bin/env bash
# After a tmux restart, map each restored pane to the Claude session id it was
# running, by position. Reads the resurrect sidecar first, then falls back to
# the newest matching row in the persistent log. Prints, per pane, the
# `claude --resume <id>` command to run. Does not auto-run anything.
set -euo pipefail

sidecar="$HOME/.local/share/tmux/resurrect/claude-ids.last"
log="$HOME/.local/share/tmux/claude-sessions.log"

lookup() { # args: session window pane ; echoes id or empty
  local s="$1" w="$2" p="$3" id=""
  if [ -f "$sidecar" ]; then
    id="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$1==s && $2==w && $3==p {print $5; exit}' "$sidecar")"
  fi
  if [ -z "$id" ] && [ -f "$log" ]; then
    # newest row (file is append-order) matching position
    id="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$3==s && $4==w && $5==p {found=$2} END{print found}' "$log")"
  fi
  printf '%s' "$id"
}

tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_index}	#{window_name}' \
| while IFS=$'\t' read -r s w p name; do
    id="$(lookup "$s" "$w" "$p")"
    if [ -n "$id" ]; then
      printf '%s:%s.%s (%s) -> claude --resume %s\n' "$s" "$w" "$p" "$name" "$id"
    fi
  done
```

Then:
```bash
chmod +x ~/dotfiles/tmux/scripts/tmux-claude-recover.sh
```

- [ ] **Step 3: Verify the reader against a synthetic sidecar (no restart needed)**

Run:
```bash
mkdir -p ~/.local/share/tmux/resurrect
cur="$(tmux display-message -p '#{session_name}	#{window_index}	#{pane_index}	#{window_name}')"
printf '%s\tsynthetic-recover-id\n' "$cur" > ~/.local/share/tmux/resurrect/claude-ids.last
~/dotfiles/tmux/scripts/tmux-claude-recover.sh
```
Expected: a line ending `-> claude --resume synthetic-recover-id` for the current pane. (Clean up: `rm ~/.local/share/tmux/resurrect/claude-ids.last` if it was only synthetic.)

- [ ] **Step 4: Apply the conf change (requires the tmux port landed; symlink picks up the new script)**

```bash
cd ~/dotfiles && git add tmux/tmux.conf tmux/scripts/tmux-claude-recover.sh
git commit -m "feat(tmux): record Claude session ids per pane for restart recovery"
home-manager switch --flake .#default --impure
```
Expected: switch succeeds; `~/.config/tmux/scripts/tmux-claude-recover.sh` exists as a Nix symlink. The `@resurrect-hook-post-save-all` line takes effect on the next fresh server that sources this conf (Phase 2 of the port plan), not the running 3.5a server.

- [ ] **Step 5: Verify the resurrect sidecar is produced on save (on a Nix-tmux server)**

On a server running the managed conf, trigger a resurrect save (`prefix Ctrl-s`, or wait for continuum), then:
```bash
cat ~/.local/share/tmux/resurrect/claude-ids.last
```
Expected: one row per Claude pane with its `@claude_session_id`; non-Claude panes excluded.

- [ ] **Step 6: Document the recovery workflow**

Add a short note to the tmux port's README/handoff (or a comment block at the top of `tmux-claude-recover.sh`) describing: after an unexpected restart, run `~/.config/tmux/scripts/tmux-claude-recover.sh` to list the `claude --resume <id>` per pane. Keep it factual; no auto-run.

---

## Self-Review Notes

- **Spec coverage:** "record which session id per window" = Task 1 (pane option + log) + Task 2 (sidecar). "Many sessions in one dir" = positional keys, not cwd slug (Global Constraints). "Whenever a session gets killed" = inverted to record-at-birth because kill-time capture is unreliable (Architecture). "Each window knows its id on resurrect" = Task 2 recovery reader keyed by `(session, window_index, pane_index)`.
- **Verified facts:** `session_id`/`cwd`/`source` stdin fields and `matcher` values confirmed via claude-code-guide (current 2026-06-25); `$TMUX_PANE` inherited by the hook confirmed live; resurrect `@resurrect-hook-post-save-all` confirmed present in the installed plugin; pane user option `@claude_session_id` round-trips through the server (verified on an isolated socket).
- **Known gaps (documented, not silently dropped):** a session born and killed entirely between two resurrect saves is absent from the sidecar but present in the persistent log (Task 1 closes the hard-crash gap). `renumber-windows on` makes the log accumulate stale position rows; the reader takes the newest row per position and uses `window_name` as a tiebreak. Subagent/child sessions are not the main pane session and are out of scope.
- **Dependency:** Task 2 edits `tmux/tmux.conf`, which must exist from the tmux port plan. Task 1 is independent and can land first.