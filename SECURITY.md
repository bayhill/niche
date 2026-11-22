# Security

Niche runs unsandboxed with the permissions its user grants it (Calendar, Automation, folders), starts a few
command-line tools (`lsof`, `gh`, `osascript`, `perl`, and `claude` when Claude Code alerts are switched on), and can
install a small plugin into Claude Code. A flaw in any of that is worth hearing about.

## Reporting

Report a vulnerability privately through GitHub: the repository's **Security** tab, then **Report a vulnerability**.
Do not open a public issue for it. Include the macOS version, how Niche was built, and the steps that show the
problem.

Reports are read by the maintainer, who replies as time allows; this is a spare-time project without a guaranteed
response time. A fix is credited to its reporter unless they would rather not be named.

## Scope

In scope: anything that lets content Niche handles (a dropped file, a calendar invitation, clipboard content, a
repository's Git configuration, the output of a tool) run code, open something unexpected, overwrite or delete a
file, or send data somewhere. Also anything the app stores or forwards that the README says it does not.

Out of scope: problems that need an attacker who already runs code as the same user with the hardened runtime
bypassed, and the behaviour of the tools Niche starts when they are used as intended.
