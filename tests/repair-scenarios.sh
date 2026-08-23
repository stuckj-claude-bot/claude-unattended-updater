#!/usr/bin/env bash
# Scenario tests for the pin repair guard and for how a resume is identified.
#
# Each case builds a throwaway CLAUDE_CONFIG_DIR and a fake `claude`, so nothing
# here touches a real session. Run from anywhere:
#
#   tests/repair-scenarios.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin/claude-unattended-update"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# The tool compares the installed version against the npm registry; reporting
# the same string from the fake keeps every case on the up-to-date path.
VERSION="$("$BIN" --version 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="9.9.9"

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         expected %s\n         got      %s\n' "$1" "$2" "$3"; fi
}

fixture() { # fixture <dir> <marker-content> <startedAt-in-listing>
  local f="$1" marker="$2" ts="$3"
  rm -rf "$f"; mkdir -p "$f/jobs/oldjob00" "$f/jobs/newjob00" "$f/projects/-h" "$f/fake"
  printf '{"name":"s","cwd":"/home/x","resumeSessionId":"sid-old"}\n' > "$f/jobs/oldjob00/state.json"
  printf '{"name":"s","cwd":"/home/x","resumeSessionId":"sid-new","respawnFlags":["--agent","claude"]}\n' \
    > "$f/jobs/newjob00/state.json"
  # Only the original job has a transcript; the resumed one never wrote hers.
  echo x > "$f/projects/-h/sid-old.jsonl"
  printf '%b' "$marker" > "$f/jobs/newjob00/.updater-pin-source"
  printf '["newjob00"]' > "$f/jobs/pins.json"
  echo 5 > "$f/jobs/newjob00/order"
  {
    echo '#!/bin/bash'
    echo "case \"\$1\" in"
    echo "  --version) echo '$VERSION';;"
    if [ "$ts" = none ]; then
      echo "  agents) echo '[]';;"
    else
      echo "  agents) echo '[{\"id\":\"newjob00\",\"sessionId\":\"sid-new\",\"cwd\":\"/home/x\",\"name\":\"s\",\"kind\":\"background\",\"status\":\"idle\",\"startedAt\":$ts}]';;"
    fi
    echo "  *) echo '$VERSION';;"
    echo "esac"
  } > "$f/fake/claude"
  chmod +x "$f/fake/claude"
}

repair() { CLAUDE_BIN="$1/fake/claude" CLAUDE_CONFIG_DIR="$1" "$BIN" --repair >/dev/null 2>&1; }
pins()   { tr -d '\n ' < "$1/jobs/pins.json"; }

echo "pin repair guard"

# A job the daemon lists is not necessarily a job that still holds its
# conversation: a respawn gives it a new process and a new start time.
fixture "$WORK/a" 'oldjob00\n' 1000; repair "$WORK/a"
check "legacy marker, job listed: repairs" '["oldjob00"]' "$(pins "$WORK/a")"

fixture "$WORK/b" 'oldjob00\nstartedAt=1000\n' 1000; repair "$WORK/b"
check "start time matches: leaves the pin alone" '["newjob00"]' "$(pins "$WORK/b")"

fixture "$WORK/c" 'oldjob00\nstartedAt=999\n' 1000; repair "$WORK/c"
check "start time differs (respawned): repairs" '["oldjob00"]' "$(pins "$WORK/c")"

fixture "$WORK/d" 'oldjob00\nstartedAt=1000\n' none; repair "$WORK/d"
check "job gone from the listing: repairs" '["oldjob00"]' "$(pins "$WORK/d")"

fixture "$WORK/e" 'oldjob00\nstartedAt=1000\n' 1000
rm -f "$WORK/e/jobs/newjob00/.updater-pin-source"
printf '{"name":"s","cwd":"/home/x","resumeSessionId":"sid-old"}\n' > "$WORK/e/jobs/newjob00/state.json"
repair "$WORK/e"
check "pinned job has its own transcript: no change" '["newjob00"]' "$(pins "$WORK/e")"

# The order file has to travel with the pin, or the pinned slot loses its place.
fixture "$WORK/f" 'oldjob00\n' 1000; repair "$WORK/f"
check "order file follows the pin" "yes" "$([ -f "$WORK/f/jobs/oldjob00/order" ] && echo yes || echo no)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
