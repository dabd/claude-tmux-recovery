#!/usr/bin/env bash
# After a tmux restart, map each restored pane to the Claude session id it was
# running, by position. Reads the resurrect sidecar first, then falls back to
# the newest matching row in the persistent log. Prints, per pane, the
# `claude --resume <id>` to run. Does not auto-run anything.
set -euo pipefail

sidecar="${TMUX_CLAUDE_SIDECAR:-$HOME/.local/share/tmux/resurrect/claude-ids.last}"
log="${TMUX_CLAUDE_LOG:-$HOME/.local/share/tmux/claude-sessions.log}"

lookup() { # args: session window pane ; echoes id or empty
  local s="$1" w="$2" p="$3" id=""
  if [ -f "$sidecar" ]; then
    id="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$1==s && $2==w && $3==p { print $5; exit }' "$sidecar")"
  fi
  if [ -z "$id" ] && [ -f "$log" ]; then
    # newest row (file is append-order) matching position
    id="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$3==s && $4==w && $5==p { found=$2 } END { print found }' "$log")"
  fi
  printf '%s' "$id"
}

tab=$'\t'
fmt="#{session_name}${tab}#{window_index}${tab}#{pane_index}${tab}#{window_name}"

tmux list-panes -a -F "$fmt" \
| while IFS=$'\t' read -r s w p name; do
    id="$(lookup "$s" "$w" "$p")"
    if [ -n "$id" ]; then
      printf '%s:%s.%s (%s) -> claude --resume %s\n' "$s" "$w" "$p" "$name" "$id"
    fi
  done
