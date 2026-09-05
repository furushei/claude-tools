# claude-tools

Hooks, agent skills, and slash commands for [Claude Code](https://claude.com/claude-code).

## Hooks

| Hook | Event | Description |
| --- | --- | --- |
| [`hooks/pushover`](hooks/pushover) | `Notification` | Pushes permission and input prompts to Pushover |

Each directory ships an `install.ps1` that deploys it to the global configuration under `~/.claude/`.

## License

MIT License. See [LICENSE](LICENSE).
