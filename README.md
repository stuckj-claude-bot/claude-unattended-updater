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

1. **Check** hourly for a new release. Nothing new, exit immediately — it is one registry lookup.
2. **Install** the new version and wait for it to land completely.
3. **Find** sessions still running the old binary.
4. **Restart** each one *only once it is genuinely idle*, then move its pin across.

Because the install finishes before any restart begins, a restart never races the
installer. Sessions are restarted properly — resumed and left running — not reaped
and left for you to rediscover.

## Install

### Debian / Ubuntu (APT)

```bash
curl -fsSL https://stuckj.github.io/claude-unattended-updater/gpg-key.asc \
  | sudo tee /usr/share/keyrings/claude-unattended-updater.asc >/dev/null

sudo tee /etc/apt/sources.list.d/claude-unattended-updater.sources >/dev/null <<'SRC'
Types: deb
URIs: https://stuckj.github.io/claude-unattended-updater/apt
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/claude-unattended-updater.asc
SRC

sudo apt update && sudo apt install claude-unattended-updater
```

The package installs the systemd **user** units; enable them for your own user,
since the updater drives that user's sessions and needs their `~/.claude`:

```bash
systemctl --user enable --now claude-unattended-update.timer
sudo loginctl enable-linger "$USER"   # so it runs while you are logged out
```

### Fedora / RHEL (YUM/DNF)

```bash
sudo tee /etc/yum.repos.d/claude-unattended-updater.repo >/dev/null <<'REPO'
[claude-unattended-updater]
name=claude-unattended-updater
baseurl=https://stuckj.github.io/claude-unattended-updater/yum
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://stuckj.github.io/claude-unattended-updater/gpg-key.asc
REPO

sudo dnf install claude-unattended-updater
```

`gpgcheck=1` verifies a signature inside each package header, which the release
workflow adds at build time and refuses to publish without.

### From source

```bash
git clone https://github.com/stuckj/claude-unattended-updater
cd claude-unattended-updater
./install.sh
```

### Required for every install method: disable the built-in updater

This tool only helps if it is the *only* thing swapping the binary:

```bash
# ~/.claude/settings.json
{ "env": { "DISABLE_AUTOUPDATER": "1" } }
```

Then restart every long-lived `claude` process — `claude agents`, `claude
remote-control`, and your login shell. A process started before that setting was
written keeps its old environment and carries on updating behind your back,
which is the failure this tool exists to prevent.

## Usage

```bash
claude-unattended-update              # what the timer runs
claude-unattended-update --dry-run    # report only, change nothing
claude-unattended-update --force      # ignore "already up to date"
claude-unattended-update --repair     # fix pins pointing at a dead session
```

Every pass also puts back any pin left pointing at a session that cannot be
resumed, so `--repair` is only needed to inspect or to fix one by hand.

Pause update runs at any time by creating the inhibit file — a pass already
waiting for a session to go idle notices it too. `--repair` and `--dry-run` are
manual and report regardless, since neither installs or restarts anything:

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
| `UPDATER_LOG` | `~/.claude/unattended-update.log` | Log file |
| `UPDATER_TMUX_SESSION` | `daemon` | tmux session name, with `UPDATER_TMUX_SOCKET` |
| `UPDATER_PASS_DEADLINE` | `43200` | Give up on the whole pass after this many seconds |
| `UPDATER_CLAUDE_TIMEOUT` | `120` | Timeout for a single `claude` query |
| `UPDATER_INSTALL_TIMEOUT` | `900` | Timeout for the install and for a session resume |

A systemd **user** service does not inherit your login shell's environment, so
exporting these from `~/.bashrc` has no effect on the timer. Set them on the
unit instead:

```bash
systemctl --user edit claude-unattended-update.service
# [Service]
# Environment=UPDATER_DEADLINE=3600
```

Checking for a new version needs either `curl` or `npm` on `PATH`; with neither,
the run exits non-zero rather than reporting success.

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
- Restarting a session leaves its previous job directory behind: `claude stop`
  does not remove one, and job scratch lives under `~/.claude/jobs/<id>/tmp`.
  Expect one orphaned directory per restarted session per release. Pruning them
  is safe once the restarted session has been prompted at least once; pruning
  earlier removes what `--repair` needs to put a pin back.
- Restarting a session starts a fresh context window. It resumes the conversation,
  it does not preserve an in-flight turn — which is why it waits for idle.

## License

MIT — see [LICENSE](LICENSE).
