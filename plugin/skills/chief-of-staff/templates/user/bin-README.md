# bin/ — your scripts

Scripts here belong to you, not to the plugin. Config keys in your config.env point at them, for example:

| Key | Your script does |
|---|---|
| `COS_NOTIFY_CMD` | reads a message on stdin and pushes it to your phone or chat |
| `COS_SPAWN_ENV_CMD` | prints `KEY=value` lines for one worker's environment (never print secrets to a terminal) |
| `COS_NEEDS_CHECK_CMD` | gets a task's `needs:` value; exit 0 = met (for example a secrets vault health check) |
| `COS_CMUX_HELPERS` | a shell file defining cmux pane helpers (layout, focus guard, pane colour) |
| `COS_HEAVY_REMOTE_CMDS` | names of your commands that run heavy jobs on another machine (the heavy-cap guard lets them through) |

Remote runners, schedulers (cron, launchd, a scheduler agent) and ship tracking also live here. Your own hooks go
in your own `settings.json`, pointing at these files. Name each script and its job in `../rules.md`.
