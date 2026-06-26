#!/usr/bin/env bash
# Claude Code SessionStart hook. Records which Claude session id is running in
# the current tmux pane, for recovery after a tmux restart. No-op outside tmux.
# Never fails the session start: always exits 0.
set -uo pipefail

input="$(cat)"   # stdin JSON from Claude Code

# Session id is the documented stdin field; cwd stored verbatim (do not slug it:
# Claude replaces both '/' and '.' with '-' in its projects dir names).
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
log="${TMUX_CLAUDE_LOG:-$HOME/.local/share/tmux/claude-sessions.log}"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\n' "$ts" "$sid" "$pos" "$cwd" >> "$log"

exit 0
