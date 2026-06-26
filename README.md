# claude-tmux-recovery

Recover Claude Code sessions after a tmux restart. When the tmux server dies and
you lose which `claude` session ran in which window, this records the mapping as
sessions start and maps restored panes back to the sessions to resume.

This repository is a Claude Code plugin marketplace with one plugin:

- **[tmux-session-recovery](plugins/tmux-session-recovery/)** - a `SessionStart`
  hook that stamps each tmux pane with its Claude session id and logs it by pane
  position, so an unexpected restart no longer loses the pane-to-session
  mapping, even when many sessions share one working directory.

## Install

```
/plugin marketplace add dabd/claude-tmux-recovery
/plugin install tmux-session-recovery@claude-tmux-recovery
```

See the [plugin README](plugins/tmux-session-recovery/README.md) for how it
works, verification, and the `CLAUDE_CONFIG_DIR` note.

## Recovery wiring (tmux-resurrect)

The plugin captures the pane-to-session mapping. To recover after a restart,
pair it with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect):

1. Snapshot each pane's id alongside every resurrect save. In `tmux.conf`:

   ```tmux
   set -g @resurrect-hook-post-save-all 'tmux list-panes -a -F "#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}\t#{@claude_session_id}" | grep -v "\t$" > ~/.local/share/tmux/resurrect/claude-ids.last'
   ```

2. After a restart, read the sidecar (and the plugin's persistent log as a
   fallback) to print, per restored pane, the `claude --resume <id>` to run.
   Match by position: `(session_name, window_index, pane_index)`, with
   `window_name` as a tiebreak.

The snapshot's worst-case staleness is the resurrect save interval; the plugin's
append log closes the gap for a session created and killed between saves.

## License

MIT. See `LICENSE`.
