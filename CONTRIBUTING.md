# Contributing

## Before you push

```bash
bash -n bin/claude-unattended-update      # syntax
shellcheck -S warning bin/claude-unattended-update
./bin/claude-unattended-update --dry-run --force   # exercises detection, changes nothing
./bin/claude-unattended-update --repair --dry-run  # exercises pin scanning
```

`--dry-run` covers everything up to the point of mutation: version check, idle
detection, and the list of sessions that would be restarted. `--force` makes it run
that path even when the installed version is already current.

## Testing the pin transfer

The pin logic mutates `~/.claude/jobs/pins.json`. Test it against a sandbox rather
than your real one — build a fake `jobs/` tree with a `pins.json` and an `order`
file, and run the block against that.

## Testing the restart path

See [CLAUDE.md](CLAUDE.md#never-test-the-restart-path-against-a-real-session).
