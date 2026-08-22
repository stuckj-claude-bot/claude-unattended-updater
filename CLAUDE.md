# Notes for AI agents

Repo-specific things that are easy to get wrong here.

- [README.md](README.md) — what the tool does, install, configuration
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to test a change safely

## Never test the restart path against a real session

Step 4 stops and resumes sessions. Exercising it against a session someone cares
about will interrupt them. Create a throwaway instead:

```bash
claude --background --name probe --model claude-haiku-4-5-20251001 "Reply with exactly: PROBE"
claude agents --json          # find its id and sessionId
claude stop <id>
claude --background --resume <sessionId> --name probe   # resumes idle, no prompt injected
```

Clean up the job dir under `~/.claude/jobs/<id>` and the transcript in
`~/.claude/projects/*/` afterwards; neither is removed by `claude stop`.

## Piping JSON into an embedded Python heredoc silently yields nothing

`python3 - "$arg" <<'PY'` makes Python read its *script* from stdin, so a pipe
feeding it JSON is consumed by the heredoc and `json.load(sys.stdin)` sees an empty
stream. Every JSON-consuming snippet here keeps its script in a shell variable and
uses `python3 -c "$PY_FOO" "$arg"` instead. This failure is silent — detection
returned "0 sessions" and looked like a clean rollout.

## `startedAt` is epoch milliseconds

`claude agents --json` returns `startedAt` as an integer, not an ISO string.
Parsing it as ISO throws, and an `except: continue` around it hides the fact that
every session was skipped.

## `claude logs <id>` is not scriptable

It emits a raw ANSI terminal dump, not text. Use `claude agents --json` for state.

## Two packaging traps that fail silently

**`dpkg-scanpackages --arch` selects on the filename.** It matches `*_all.deb`
and `*_<arch>.deb`, not the control file's `Architecture` field. Renaming a
package asset away from nfpm's default produces empty indexes with every command
still exiting 0. `scripts/build-package-repos.sh` fails loudly on an empty index
for this reason — do not "fix" that guard by removing it.

**An unsigned rpm is not a build error, and `rpm --checksig` cannot tell you so
here.** Only the header signature satisfies `gpgcheck=1`; signing `repomd.xml`
does not. `rpm --checksig` checks against rpm's own keyring, and `rpm --import`
needs an initialised rpm database, which Debian-family hosts lack — it fails
silently, taking the check with it. Both the release workflow and the repository
builder read `%{RSAHEADER:pgpsig}` and `%{SIGPGP:pgpsig}` off the package
instead, and treat `(none)|(none)` as unsigned.
