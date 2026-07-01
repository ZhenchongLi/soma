#!/bin/sh
# soma CLI tour — a guided walk through the soma daemon over the packaged `soma`
# command. Every beat is one (or two) real CLI calls; nothing is faked.
#
# The point of the tour: an agent run on soma is a supervised OTP process tree,
# not a while-loop. So you can watch it (1) run a multi-step task, (2) cancel
# a live task for real, (3) survive a crashing tool without taking the daemon
# down, (4) replay the whole thing as an audit trace, and (5) answer an intent
# through a real model.
#
# Usage:
#   examples/cli-demo/demo.sh           # interactive, pauses between beats
#   NO_PAUSE=1 examples/cli-demo/demo.sh   # run straight through (for CI / re-record)
#
# The `soma ask` beat (5) is skipped unless ~/.soma/config exists and
# SOMA_LLM_API_KEY is set — see README.md.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ROOT="/tmp/soma-demo"

# --- locate the soma command -------------------------------------------------
if [ -x "$REPO/_build/default/rel/somad/bin/soma" ]; then
    SOMA="$REPO/_build/default/rel/somad/bin/soma"
elif command -v soma >/dev/null 2>&1; then
    SOMA="soma"
else
    echo "Can't find the soma command." >&2
    echo "Build the release first, from the repo root:  rebar3 release" >&2
    exit 1
fi

# --- pretty helpers ----------------------------------------------------------
title() { printf '\n\033[1;33m== %s ==\033[0m\n' "$1"; }
note()  { printf '\033[2m%s\033[0m\n' "$1"; }
cmd()   { printf '\033[36m$ soma %s\033[0m\n' "$*"; }
pause() {
    [ "${NO_PAUSE:-0}" = "1" ] && return
    printf '\033[2m  -- enter to continue --\033[0m'
    # read from the terminal even if stdin is redirected
    if [ -r /dev/tty ]; then read -r _ < /dev/tty; else read -r _; fi
    printf '\n'
}

cd "$HERE"

note "using: $SOMA"
note "(the first call auto-starts the daemon if none is running)"

# --- setup -------------------------------------------------------------------
mkdir -p "$ROOT"
printf 'the quick brown fox\n' > "$ROOT/input.txt"
rm -f "$ROOT/output.txt"
note "wrote $ROOT/input.txt"
pause

# === BEAT 1: a supervised multi-step task run ================================
title "1. run a task: file_read -> echo -> file_write"
note "Three steps, run in order, each in its own supervised tool-call process."
cmd "run pipeline.lfe"
OUT=$("$SOMA" run pipeline.lfe); STATUS=$?
echo "$OUT"
note "[exit $STATUS]"
echo "--- $ROOT/output.txt now holds: ---"
cat "$ROOT/output.txt"
CORR=$(printf '%s' "$OUT" | sed -n 's/.*(correlation-id "\([^"]*\)").*/\1/p')
pause

# === BEAT 2: cancel a live task for real =====================================
title "2. cancel a running task"
note "Start a 60s sleep detached, see it 'running', then cancel it. The run stops"
note "its active tool worker and reports 'cancelled' — the daemon never blinks."
cmd "run slow.lfe --detach"
ACC=$("$SOMA" run slow.lfe --detach)
echo "$ACC"
TASK=$(printf '%s' "$ACC" | sed -n 's/.*(task-id "\([^"]*\)").*/\1/p')
cmd "status $TASK"
"$SOMA" status "$TASK"
cmd "cancel $TASK"
"$SOMA" cancel "$TASK"
cmd "status $TASK"
"$SOMA" status "$TASK"
pause

# === BEAT 3: crash isolation =================================================
title "3. a crashing tool does not take the daemon down"
note "The 'fail' tool's worker process actually crashes. The run catches it as"
note "data (status failed, error noproc = the process went away) — then the very"
note "next run completes. Failure is isolated by a process boundary, not try/catch."
cmd "run crash.lfe"
"$SOMA" run crash.lfe; note "[exit $? — expected non-zero]"
cmd "run pipeline.lfe   (daemon still serving?)"
"$SOMA" run pipeline.lfe >/dev/null && note "[exit 0 — daemon is fine]"
pause

# === BEAT 4: the audit trace =================================================
title "4. replay the whole pipeline as an audit trace"
note "Every event, in order, as Lisp. Note each tool call ran in its own"
note "process (tool-call-pid) — visible proof of 'a process per unit of work'."
if [ -n "$CORR" ]; then
    cmd "trace $CORR"
    "$SOMA" trace "$CORR"
else
    note "(could not parse a correlation-id from beat 1; skipping)"
fi
pause

# === BEAT 5: the agent — soma ask (needs a model) ============================
title "5. ask the agent (real model)"
if [ -f "$HOME/.soma/config" ] && [ -n "${SOMA_LLM_API_KEY:-}" ]; then
    note "Config + key found. Restarting the daemon so it loads ~/.soma/config..."
    "$SOMA" stop >/dev/null 2>&1 || true
    sleep 1
    cmd 'ask "in one sentence, what is Erlang/OTP good at?"'
    "$SOMA" ask "in one sentence, what is Erlang/OTP good at?"
else
    note "Skipped — no model configured yet. To enable this beat:"
    note "  cp examples/cli-demo/config.example ~/.soma/config   # edit if needed"
    note "  export SOMA_LLM_API_KEY=\"<your key>\""
    note "  soma stop        # so the daemon reloads config on next call"
    note "Then re-run this script."
fi

title "done"
note "The daemon is still running. Stop it with:  $SOMA stop"
