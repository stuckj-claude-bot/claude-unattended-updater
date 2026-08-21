# claude-unattended-updater

Apply Claude Code updates on an unattended box without killing work in progress.

## The problem

Claude Code's background updater swaps `claude.exe` in place. The agent daemon's
supervisor watches that file's mtime and re-execs itself when it changes — but if it
fires while the installer is still writing, the respawn dies with `EACCES`, nothing
supervises the running sessions, and an orphan watchdog reaps every one of them
60 seconds later.

On one box over a week that was **457 upgrade-triggered supervisor restarts, every
single one with live sessions attached**, and **21 lost races** that reaped whatever
was running. Sessions died mid-task, and because a reaped daemon cannot be revived
remotely, recovering meant physically getting to the machine — which defeats the
point of driving Claude Code from a phone.

## What this does

One engine owns the whole sequence, so nothing races it:

1. **Check** hourly for a new release. Nothing new, exit immediately — it is one
   `npm view` call.
2. **Install** the new version and wait for it to land completely.
3. **Find** sessions still running the old binary.
4. **Restart** each one *only once it is genuinely idle*, then move its pin across.

Because the install finishes before any restart begins, a restart never races the
installer. Sessions are restarted properly — resumed and left running — not reaped
and left for you to rediscover.

## Install

```bash
git clone https://github.com/stuckj/claude-unattended-updater
cd claude-unattended-updater
./install.sh
```

Then turn off the built-in updater so this is the only thing swapping the binary:

```bash
# ~/.claude/settings.json
{ "env": { "DISABLE_AUTOUPDATER": "1" } }
```

Restart any long-lived `claude` process afterwards — `claude agents`, `claude
remote-control`, and your login shell. A process started before that setting was
written keeps its old environment and will carry on updating behind your back.

## Usage

```bash
claude-unattended-update              # what the timer runs
claude-unattended-update --dry-run    # report only, change nothing
claude-unattended-update --force      # ignore "already up to date"
claude-unattended-update --repair     # fix pins pointing at a dead session
```

Pause it at any time by creating the inhibit file:

```bash
touch ~/.claude/no-auto-update
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `UPDATER_POLL` | `60` | Seconds between idle polls |
| `UPDATER_IDLE_STREAK` | `2` | Consecutive idle polls required before a restart |
| `UPDATER_DEADLINE` | `21600` | Give up waiting for a session after this many seconds |
| `UPDATER_TMUX_SOCKET` | unset | Keep the restarted daemon in this tmux socket |
| `CLAUDE_BIN` | from `PATH` | Path to the `claude` wrapper |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code config directory |

## What "idle" means

`claude agents --json` reports `status: busy` for anything mid-turn — including
sub-agents and tool sub-shells — so a session is only restarted when that reads
`idle` on `UPDATER_IDLE_STREAK` consecutive polls. Requiring a streak keeps a
momentary gap between two tool calls from being mistaken for the end of a turn.

## Why it moves your pins

Resuming a session mints a **new job id and a new session id**, and writes no
transcript for the new id until that session next receives a prompt. So a naive
restart leaves `pins.json` pointing at a job that no longer exists, and `claude
agents` then refuses to resume it with *"No conversation found with session ID"* —
the conversation is intact, the pointer is not.

Step 4 moves the pin (both the `pins.json` entry and the job's `order` file) to the
new job id. `--repair` fixes pins that already went stale this way, matching a
phantom pin to the job that really owns the transcript.

## Caveats

- Linux and systemd only; it reads `/proc` for supervisor liveness.
- The supervisor's own mtime watch cannot be unsubscribed. Installing while all
  sessions are idle bounds the damage of a lost race, and the engine detects a
  dead supervisor and restarts it, but it cannot prevent the watch from firing.
- Restarting a session starts a fresh context window. It resumes the conversation,
  it does not preserve an in-flight turn — which is why it waits for idle.

## License

MIT — see [LICENSE](LICENSE).
