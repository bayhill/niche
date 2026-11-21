# Notcher bridge

Installed by the Notcher app when Claude alerts are turned on. Each hook passes a few short fields of the event
(session id, working folder, event name, tool name, notification type, title and message, each cut to 200
characters) to `~/Library/Application Support/Notcher/claude-events/`, where Notcher reads and deletes them to show
which sessions need permission or input, or have just finished. Prompts, tool input and tool output are never
written. The script prints nothing, never blocks a session, and does nothing while that folder is missing (Notcher
not running, or alerts off) or already holds more than 50 unread events.
