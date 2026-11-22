# Notcher bridge

Installed by the Notcher app when Claude alerts are turned on. Each hook writes a few short fields of the event to
`~/Library/Application Support/Notcher/claude-events/`, where Notcher reads and deletes them to show which sessions
need permission or input, or have just finished. These are the only fields written, each cut to 200 characters:

| Event | Fields |
| --- | --- |
| every event | `session_id`, `hook_event_name`, `cwd` (the session's working folder), `session_title` |
| `PermissionRequest`, `PostToolUse`, `PostToolUseFailure` | `tool_name` |
| `Notification` | `notification_type`, `message` |
| `SessionStart` | `source` |
| `SessionEnd` | `reason` |
| `StopFailure` | `error` |

`session_title` is the session's title when it has one, which can be a summary of the first prompt. `message` is
Claude Code's notification text, such as which tool needs permission or what input is wanted. Prompts, tool input,
tool output and the transcript are never written, and `error` is kept only for `StopFailure` (the API error that ended
a turn), because for a failed tool call it can hold the command's output.

The script prints nothing, never blocks a session, and does nothing while that folder is missing (Notcher not running,
or alerts off) or already holds more than 50 unread events.
