# Notcher bridge

Installed by the Notcher app when you turn on Claude alerts. Each hook copies the event's JSON into
`~/Library/Application Support/Notcher/claude-events/`, where Notcher reads it to show which sessions need
your permission or input, or have just finished. The script prints nothing, never blocks a session, and does
nothing at all while that folder is missing (Notcher not installed, or alerts turned off).
