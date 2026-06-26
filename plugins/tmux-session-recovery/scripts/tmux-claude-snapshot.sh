#!/usr/bin/env bash
# tmux-resurrect post-save-all hook. Snapshots each pane's Claude session id by
# position, alongside the resurrect save, so a restored pane can find which
# session it was running. Panes with no @claude_session_id are dropped.
#
# Wire it in tmux.conf:
#   set -g @resurrect-hook-post-save-all 'run-shell "/path/to/tmux-claude-snapshot.sh"'
set -euo pipefail

out="${TMUX_CLAUDE_SIDECAR:-$HOME/.local/share/tmux/resurrect/claude-ids.last}"
mkdir -p "$(dirname "$out")" 2>/dev/null || true

tab=$'\t'
fmt="#{session_name}${tab}#{window_index}${tab}#{pane_index}${tab}#{window_name}${tab}#{@claude_session_id}"

# Keep only panes whose @claude_session_id is non-empty (line does not end at a tab).
tmux list-panes -a -F "$fmt" | awk -F'\t' 'NF==5 && $5 != "" { print }' > "$out"
