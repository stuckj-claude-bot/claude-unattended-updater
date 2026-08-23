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

VERSION=9.9.9

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         expected %s\n         got      %s\n' "$1" "$2" "$3"; fi
}

fixture() { # fixture <dir> <marker-content> <startedAt-in-listing>
  local f="$1" marker="$2" ts="$3"
  rm -rf "$f"; mkdir -p "$f/jobs/oldjob00" "$f/jobs/aa11bb22" "$f/projects/-h" "$f/fake"
  printf '{"name":"s","cwd":"/home/x","resumeSessionId":"sid-old"}\n' > "$f/jobs/oldjob00/state.json"
  printf '{"name":"s","cwd":"/home/x","resumeSessionId":"sid-new","respawnFlags":["--agent","claude"]}\n' \
    > "$f/jobs/aa11bb22/state.json"
  # Only the original job has a transcript; the resumed one never wrote hers.
  echo x > "$f/projects/-h/sid-old.jsonl"
  printf '%b' "$marker" > "$f/jobs/aa11bb22/.updater-pin-source"
  printf '["aa11bb22"]' > "$f/jobs/pins.json"
  echo 5 > "$f/jobs/aa11bb22/order"
  {
    echo '#!/bin/bash'
    echo "case \"\$1\" in"
    echo "  --version) echo '$VERSION';;"
    if [ "$ts" = none ]; then
      echo "  agents) echo '[]';;"
    else
      echo "  agents) echo '[{\"id\":\"aa11bb22\",\"sessionId\":\"sid-new\",\"cwd\":\"/home/x\",\"name\":\"s\",\"kind\":\"background\",\"status\":\"idle\",\"startedAt\":$ts}]';;"
    fi
    echo "  *) echo '$VERSION';;"
    echo "esac"
  } > "$f/fake/claude"
  chmod +x "$f/fake/claude"
}

repair() { # exit status is part of what these cases assert
  CLAUDE_BIN="$1/fake/claude" CLAUDE_CONFIG_DIR="$1" "$BIN" --repair >"$1/out" 2>&1
  echo $? > "$1/rc"
}
pins()   { tr -d '\n ' < "$1/jobs/pins.json"; }

echo "pin repair guard"

# A job the daemon lists is not necessarily a job that still holds its
# conversation: a respawn gives it a new process and a new start time. Absent a
# recorded start time the two are indistinguishable, so a live job keeps its pin.
fixture "$WORK/a" 'oldjob00\n' 1000; repair "$WORK/a"
check "no recorded start time, job listed: leaves the pin alone" '["aa11bb22"]' "$(pins "$WORK/a")"
check "  and exits 0" "0" "$(cat "$WORK/a/rc")"

fixture "$WORK/a2" 'oldjob00\n' none; repair "$WORK/a2"
check "no recorded start time, job gone: repairs" '["oldjob00"]' "$(pins "$WORK/a2")"

fixture "$WORK/b" 'oldjob00\nstartedAt=1000\n' 1000; repair "$WORK/b"
check "start time matches: leaves the pin alone" '["aa11bb22"]' "$(pins "$WORK/b")"

fixture "$WORK/c" 'oldjob00\nstartedAt=999\n' 1000; repair "$WORK/c"
check "start time differs (respawned): repairs" '["oldjob00"]' "$(pins "$WORK/c")"

fixture "$WORK/d" 'oldjob00\nstartedAt=1000\n' none; repair "$WORK/d"
check "job gone from the listing: repairs" '["oldjob00"]' "$(pins "$WORK/d")"

fixture "$WORK/e" 'oldjob00\nstartedAt=1000\n' 1000
rm -f "$WORK/e/jobs/aa11bb22/.updater-pin-source"
printf '{"name":"s","cwd":"/home/x","resumeSessionId":"sid-old"}\n' > "$WORK/e/jobs/aa11bb22/state.json"
repair "$WORK/e"
check "pinned job has its own transcript: no change" '["aa11bb22"]' "$(pins "$WORK/e")"

# The order file has to travel with the pin, or the pinned slot loses its place.
fixture "$WORK/f" 'oldjob00\nstartedAt=999\n' 1000; repair "$WORK/f"
check "order file follows the pin" "yes" "$([ -f "$WORK/f/jobs/oldjob00/order" ] && echo yes || echo no)"

# The cases above hand-write .updater-pin-source, so they cannot catch a marker
# writer that disagrees with the reader. This one runs a real rollout through the
# program and only then asks whether the pin survives.
echo
echo "rollout end to end"

E="$WORK/e2e"
mkdir -p "$E/jobs/oldjob00" "$E/projects/-h" "$E/fake" "$E/wd"
printf '{"name":"s","cwd":"%s/wd","resumeSessionId":"sid-old","respawnFlags":["--model","opus"]}\n' "$E" \
  > "$E/jobs/oldjob00/state.json"
echo x > "$E/projects/-h/sid-old.jsonl"
printf '["oldjob00"]' > "$E/jobs/pins.json"
echo 5 > "$E/jobs/oldjob00/order"
OLD_TS=1000
NEW_TS=2000
cat > "$E/fake/claude" <<FAKE
#!/bin/bash
case "\$1" in
  --version) echo "$VERSION";;
  agents)
    if [ -f "$E/resumed" ]; then
      echo '[{"id":"aa11bb22","sessionId":"sid-new","cwd":"$E/wd","name":"s","kind":"background","status":"idle","startedAt":$NEW_TS}]'
    elif [ -f "$E/down" ]; then
      echo '[]'
    else
      echo '[{"id":"oldjob00","sessionId":"sid-old","cwd":"$E/wd","name":"s","kind":"background","status":"idle","startedAt":$OLD_TS}]'
    fi;;
  stop) touch "$E/down"; exit 0;;
  --background)
    touch "$E/resumed"
    mkdir -p "$E/jobs/aa11bb22"
    printf '{"name":"s","cwd":"$E/wd","resumeSessionId":"sid-new","respawnFlags":["--model","opus"]}\\n' \\
      > "$E/jobs/aa11bb22/state.json"
    echo "backgrounded · aa11bb22 · s";;
  *) echo "$VERSION";;
esac
FAKE
chmod +x "$E/fake/claude"
# latest_version reads the registry; a stub keeps the suite off the network.
mkdir -p "$E/bin"
cat > "$E/bin/curl" <<CURL
#!/bin/bash
printf '%s' '{"version":"$VERSION"}'
CURL
chmod +x "$E/bin/curl"

PATH="$E/bin:$PATH" CLAUDE_BIN="$E/fake/claude" CLAUDE_CONFIG_DIR="$E" \
  UPDATER_POLL=1 UPDATER_IDLE_STREAK=1 "$BIN" --force >"$E/out" 2>&1
check "rollout moves the pin to the resumed job" '["aa11bb22"]' "$(tr -d '\n ' < "$E/jobs/pins.json")"
check "marker names the source job" "oldjob00" \
  "$(head -1 "$E/jobs/aa11bb22/.updater-pin-source" 2>/dev/null)"
# Without this line the repair guard cannot tell a live resume from a respawn,
# and every later pass hands the pin back to the job it stopped.
check "marker records the resumed start time" "startedAt=$NEW_TS" \
  "$(sed -n 2p "$E/jobs/aa11bb22/.updater-pin-source" 2>/dev/null)"

PATH="$E/bin:$PATH" repair "$E"
check "repair after a rollout leaves the pin alone" '["aa11bb22"]' "$(tr -d '\n ' < "$E/jobs/pins.json")"
check "repair exits 0" "0" "$(cat "$E/rc")"

# A resume that reports failure after the session came up must not be retried:
# the retry would start a second agent on the same conversation.
R="$WORK/rc"
mkdir -p "$R/jobs/oldjob00" "$R/projects/-h" "$R/fake" "$R/wd" "$R/bin"
printf '{"name":"s","cwd":"%s/wd","resumeSessionId":"sid-old","respawnFlags":["--model","opus"]}\n' "$R" \
  > "$R/jobs/oldjob00/state.json"
echo x > "$R/projects/-h/sid-old.jsonl"
printf '["oldjob00"]' > "$R/jobs/pins.json"
cat > "$R/fake/claude" <<FAKE
#!/bin/bash
case "\$1" in
  --version) echo "$VERSION";;
  agents)
    if [ -f "$R/resumed" ]; then
      echo '[{"id":"cc33dd44","sessionId":"sid-new","cwd":"$R/wd","name":"s","kind":"background","status":"idle","startedAt":2000}]'
    elif [ -f "$R/down" ]; then echo '[]'
    else echo '[{"id":"oldjob00","sessionId":"sid-old","cwd":"$R/wd","name":"s","kind":"background","status":"idle","startedAt":1000}]'; fi;;
  stop) touch "$R/down"; exit 0;;
  --background)
    touch "$R/resumed"
    mkdir -p "$R/jobs/cc33dd44"
    printf '{"name":"s","cwd":"$R/wd","resumeSessionId":"sid-new","respawnFlags":["--model","opus"]}\\n' \\
      > "$R/jobs/cc33dd44/state.json"
    echo "the session started but I am reporting failure"
    exit 124;;
  *) echo "$VERSION";;
esac
FAKE
chmod +x "$R/fake/claude"
cp "$E/bin/curl" "$R/bin/curl"
PATH="$R/bin:$PATH" CLAUDE_BIN="$R/fake/claude" CLAUDE_CONFIG_DIR="$R" \
  UPDATER_POLL=1 UPDATER_IDLE_STREAK=1 "$BIN" --force >"$R/out" 2>&1
check "a resume that came up despite a non-zero exit is adopted" '["cc33dd44"]' \
  "$(tr -d '\n ' < "$R/jobs/pins.json")"
check "  and is not recorded as failed" "absent" \
  "$([ -f "$R/unattended-update-state.json" ] && echo present || echo absent)"

# A job this tool resumed has no transcript under its own session id until it
# is prompted, so a later rollout that resumes that id finds nothing and the
# session is destroyed. It has to resume the source session instead.
S2="$WORK/second"
mkdir -p "$S2/jobs/srcjob00" "$S2/jobs/resumed1" "$S2/projects/-h" "$S2/fake" "$S2/wd" "$S2/bin"
printf '{"name":"s","cwd":"%s/wd","resumeSessionId":"sid-src","respawnFlags":["--model","opus"]}\n' "$S2" \
  > "$S2/jobs/srcjob00/state.json"
printf '{"name":"s","cwd":"%s/wd","resumeSessionId":"sid-resumed","respawnFlags":["--model","opus"]}\n' "$S2" \
  > "$S2/jobs/resumed1/state.json"
# Only the source job ever wrote a transcript.
echo x > "$S2/projects/-h/sid-src.jsonl"
printf 'srcjob00\nstartedAt=1000\n' > "$S2/jobs/resumed1/.updater-pin-source"
printf '["resumed1"]' > "$S2/jobs/pins.json"
cat > "$S2/fake/claude" <<FAKE
#!/bin/bash
case "\$1" in
  --version) echo "$VERSION";;
  agents)
    if [ -f "$S2/resumed" ]; then
      echo '[{"id":"dd44ee55","sessionId":"sid-2","cwd":"$S2/wd","name":"s","kind":"background","status":"idle","startedAt":3000}]'
    elif [ -f "$S2/down" ]; then echo '[]'
    else echo '[{"id":"resumed1","sessionId":"sid-resumed","cwd":"$S2/wd","name":"s","kind":"background","status":"idle","startedAt":1000}]'; fi;;
  stop) touch "$S2/down"; exit 0;;
  --background)
    shift; want=""
    while [ \$# -gt 0 ]; do [ "\$1" = "--resume" ] && { want="\$2"; break; }; shift; done
    echo "\$want" >> "$S2/resumed-with"
    # The real CLI refuses a session id with no transcript.
    if [ ! -f "$S2/projects/-h/\$want.jsonl" ]; then
      echo "No conversation found with session ID: \$want"; exit 1
    fi
    touch "$S2/resumed"
    mkdir -p "$S2/jobs/dd44ee55"
    printf '{"name":"s","cwd":"$S2/wd","resumeSessionId":"sid-2","respawnFlags":["--model","opus"]}\\n' \\
      > "$S2/jobs/dd44ee55/state.json"
    echo "backgrounded · dd44ee55 · s";;
  *) echo "$VERSION";;
esac
FAKE
chmod +x "$S2/fake/claude"
cp "$E/bin/curl" "$S2/bin/curl"
PATH="$S2/bin:$PATH" CLAUDE_BIN="$S2/fake/claude" CLAUDE_CONFIG_DIR="$S2" \
  UPDATER_POLL=1 UPDATER_IDLE_STREAK=1 "$BIN" --force >"$S2/out" 2>&1
check "a second rollout resumes the source session, not the empty one" "sid-src" \
  "$(head -1 "$S2/resumed-with" 2>/dev/null)"
check "  and the session comes back" '["dd44ee55"]' "$(tr -d '\n ' < "$S2/jobs/pins.json")"
check "  with nothing recorded as failed" "absent" \
  "$([ -f "$S2/unattended-update-state.json" ] && echo present || echo absent)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
