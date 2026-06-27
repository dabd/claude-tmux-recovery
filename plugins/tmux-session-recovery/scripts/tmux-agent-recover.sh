#!/usr/bin/env bash
# After a tmux restart, map each restored pane to the AI-agent session id it was
# running, by position. Reads the resurrect sidecar first, then falls back to
# the newest matching row in the persistent log. Prints, per pane, the resume
# command to run (`claude --resume <id>` or `codex resume <id>`). Agent-neutral.
# Does not auto-run anything.
set -euo pipefail

sidecar="${TMUX_AGENT_SIDECAR:-${TMUX_CLAUDE_SIDECAR:-$HOME/.local/share/tmux/resurrect/agent-ids.last}}"
log="${TMUX_AGENT_LOG:-${TMUX_CLAUDE_LOG:-$HOME/.local/share/tmux/claude-sessions.log}}"

# resume_cmd <agent_kind> <id> -> the command string to relaunch that session.
resume_cmd() {
  case "$1" in
    codex) printf 'codex resume %s' "$2" ;;
    *)     printf 'claude --resume %s' "$2" ;;   # default/claude
  esac
}

# lookup <session> <window> <pane> -> "<agent_kind>\t<id>" or empty.
# Sidecar is the 6-column agent format (kind in $5, id in $6). The persistent
# log is Claude-only by construction, so its fallback hits are kind "claude".
lookup() {
  local s="$1" w="$2" p="$3" hit=""
  if [ -f "$sidecar" ]; then
    hit="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$1==s && $2==w && $3==p { print $5 "\t" $6; exit }' "$sidecar")"
  fi
  if [ -z "$hit" ] && [ -f "$log" ]; then
    local id
    id="$(awk -F'\t' -v s="$s" -v w="$w" -v p="$p" \
      '$3==s && $4==w && $5==p { found=$2 } END { print found }' "$log")"
    [ -n "$id" ] && hit="claude${tab}${id}"
  fi
  printf '%s' "$hit"
}

tab=$'\t'
fmt="#{session_name}${tab}#{window_index}${tab}#{pane_index}${tab}#{window_name}"

tmux list-panes -a -F "$fmt" \
| while IFS=$'\t' read -r s w p name; do
    hit="$(lookup "$s" "$w" "$p")"
    if [ -n "$hit" ]; then
      kind="${hit%%$'\t'*}"
      id="${hit#*$'\t'}"
      printf '%s:%s.%s (%s) -> %s\n' "$s" "$w" "$p" "$name" "$(resume_cmd "$kind" "$id")"
    fi
  done
