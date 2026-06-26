# tmux-session-recovery

Record which Claude Code session id runs in each tmux pane, so an unexpected
tmux restart no longer loses the mapping. After a restart you can resume each
window with the session it was running, even when many sessions share one
working directory.

## The problem

When you run several `claude` sessions across tmux windows and the tmux server
dies (crash, reboot, accidental `kill-server`), you lose which session id ran in
which window. Recovering it by hand means tracing logs. Matching by working
directory does not help if you run many sessions in the same directory: they all
share one `~/.claude/projects/<dir>/` folder.

## How it works

Recording happens at session start, not at kill time. A tmux hook cannot read a
dead pane's environment, and a shell trap does not fire on a hard kill, so
capturing "when the session ends" is unreliable. Instead a Claude Code
`SessionStart` hook fires when a session starts or resumes and does two things:

1. Stamps the live session id onto the pane as the tmux option
   `@claude_session_id` (queryable from the tmux server).
2. Appends one row to `~/.local/share/tmux/claude-sessions.log`, keyed by pane
   position (`session_name`, `window_index`, `pane_index`, `window_name`) plus
   the working directory. Position is the key that survives a restart, which is
   what makes recovery work when several sessions share a directory.

The session id comes from the hook's stdin JSON (`session_id`). The working
directory is stored verbatim; it is not turned into a Claude projects slug
(Claude replaces both `/` and `.` with `-`, so reconstructing the slug is
error-prone).

## Install

This plugin ships in the `claude-tmux-recovery` marketplace. Add the marketplace
and enable the plugin:

```
/plugin marketplace add dabd/claude-tmux-recovery
/plugin install tmux-session-recovery@claude-tmux-recovery
```

If you run more than one Claude config via `CLAUDE_CONFIG_DIR` (for example a
work `~/.claude` and a personal `~/.claude-personal`), enable the plugin in each:
config dirs are isolated, so a plugin enabled in one does not apply to the other.

## Verify

From inside a tmux pane, feed the hook a synthetic event:

```bash
echo '{"session_id":"test-uuid-1234","cwd":"/tmp","hook_event_name":"SessionStart","source":"startup"}' \
  | "$CLAUDE_PLUGIN_ROOT/scripts/record-tmux-session.sh"
tmux show -p @claude_session_id          # -> @claude_session_id test-uuid-1234
tail -1 ~/.local/share/tmux/claude-sessions.log
```

Outside tmux the hook is a no-op and exits 0, so it never blocks a session start.

## Configuration

- `TMUX_CLAUDE_LOG` overrides the log path (default
  `~/.local/share/tmux/claude-sessions.log`).

## Recovery after a restart

The capture half is this plugin. Pairing it with tmux-resurrect closes the loop:
a `@resurrect-hook-post-save-all` line snapshots each pane's id alongside the
resurrect save, and a reader maps restored panes back to `claude --resume <id>`
by position. See the repository README for the resurrect wiring.

## License

MIT. See `LICENSE`.
