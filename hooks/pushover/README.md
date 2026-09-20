# Pushover notification hook

Pushes Claude Code `Notification` events (waiting for permission or input) to [Pushover](https://pushover.net/).

| File | Purpose |
| --- | --- |
| `pushover-notify.ps1` | The hook itself. Reads the JSON payload from stdin and POSTs it to Pushover |
| `install.ps1` | Copies the hook to `~/.claude/hooks/` and registers (or removes) it in `~/.claude/settings.json` |
| `pushover.json.example` | Template for the credentials file |

## Setup

1. Create an application in Pushover and note its **API Token** and your **User Key**.
2. Provide the credentials one of two ways:

   - `~/.claude/pushover.json` (recommended)

     ```json
     {
       "token": "<API Token>",
       "user": "<User Key>",
       "priority": 0,
       "sound": "pushover",
       "device": "",
       "cooldown": 60
     }
     ```

     `priority`, `sound`, `device` and `cooldown` are optional.

   - The `PUSHOVER_TOKEN` / `PUSHOVER_USER` / `PUSHOVER_COOLDOWN` environment variables, which take precedence over the file.

3. Install:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File hooks\pushover\install.ps1
   ```

4. Reload the configuration by opening `/hooks` once in Claude Code, or restart the session.

To remove it, run `install.ps1 -Uninstall`. Other settings and other hooks in `~/.claude/settings.json` are preserved.

## How it works

The installer adds this entry to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\<you>\\.claude\\hooks\\pushover-notify.ps1"],
            "async": true,
            "timeout": 15,
            "statusMessage": "Sending Pushover notification"
          }
        ]
      }
    ]
  }
}
```

- The notification title is the project name taken from the payload's `cwd` (`Claude Code: claude-tools`); the body is `message`.
- `async: true`, so the session is never blocked.
- The hook **always exits 0**, including when credentials are missing or the push fails. The reason goes to stderr only; the session keeps running.
- It runs under `powershell.exe` (Windows PowerShell 5.1), not `pwsh`. The settings key `"shell": "powershell"` requires `pwsh`, so the hook is launched directly through the `args` exec form instead.

## Throttling

To avoid a burst of pushes, once a notification has been sent, further ones from the **same session** (keyed by the payload's `session_id`, falling back to `cwd`) are suppressed for `cooldown` seconds.

- Default is `60`; `0` disables throttling. Set it in `pushover.json` or with `PUSHOVER_COOLDOWN` (the env var wins).
- Different sessions throttle independently, so a second project is never silenced by the first.
- The window is a fixed one measured from the last *sent* push. Suppressed notifications are dropped, not queued or merged, so a different message arriving inside the window is dropped too.
- A push that fails (bad credentials, network error) does not start a window.
- State is one small `*.stamp` file per session in `~/.claude/hooks/pushover-state/` (override with `PUSHOVER_STATE_DIR`); its modification time is the last-sent time. Stamps older than 7 days are cleaned up automatically. A named mutex makes the check-and-claim atomic when hooks fire at the same moment.
- If the throttle itself breaks (unwritable state directory, etc.), it fails open and the notification is sent anyway.
- Suppressions are logged to stderr only (`suppressed (last push 12s ago, cooldown 60s)`).

## Trying it locally

```powershell
$env:PUSHOVER_TOKEN = '<API Token>'
$env:PUSHOVER_USER  = '<User Key>'
'{"hook_event_name":"Notification","message":"test","cwd":"C:/Users/you/repos/claude-tools"}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File hooks\pushover\pushover-notify.ps1
```

On success nothing is printed to the terminal and the notification arrives on your device.
