# claude-tmux-recovery

Recover Claude Code sessions after a tmux restart.

The tmux server dies. You lose which `claude` session ran in which window. This records the mapping as sessions start, then maps restored panes back to the sessions to resume.

A Claude Code plugin marketplace with one plugin:

- **[tmux-session-recovery](plugins/tmux-session-recovery/)** stamps each tmux pane with its Claude session id and logs it by pane position. An unexpected restart no longer loses the pane-to-session mapping. Position is the key, so it works even when many sessions share one directory.

## Install

```
/plugin marketplace add dabd/claude-tmux-recovery
/plugin install tmux-session-recovery@claude-tmux-recovery
```

The [plugin README](plugins/tmux-session-recovery/README.md) covers how it works, verification, and the `CLAUDE_CONFIG_DIR` note.

## Recovery wiring (tmux-resurrect)

The plugin captures the mapping. Recovery pairs it with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect).

1. Snapshot each pane's id alongside every resurrect save. In `tmux.conf`:

   ```tmux
   set -g @resurrect-hook-post-save-all 'tmux list-panes -a -F "#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}\t#{@claude_session_id}" | grep -v "\t$" > ~/.local/share/tmux/resurrect/claude-ids.last'
   ```

2. After a restart, read the sidecar to print `claude --resume <id>` per restored pane. The plugin's append log is the fallback. Match by position `(session_name, window_index, pane_index)`, with `window_name` as a tiebreak.

Worst-case staleness is the resurrect save interval. The append log closes the gap for a session born and killed between saves.

## License

MIT. See `LICENSE`.
