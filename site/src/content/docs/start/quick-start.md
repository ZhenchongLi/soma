---
title: Quick start
description: Build Soma, run the test contract, and drive the file_read → echo → file_write demo.
---

Soma is an Erlang/OTP umbrella. You build it, run its test contract, and drive a
run from the shell. Everything below assumes Erlang/OTP 29 and rebar3 are on your
path.

## Build and test

Compile the umbrella, then run both gates. The merge gate is exactly these two
commands — EUnit for the unit layer, Common Test for the process-behaviour layer.

```bash
rebar3 compile      # build the umbrella
rebar3 eunit        # unit tests
rebar3 ct           # process-behaviour / end-to-end tests
```

`rebar3 ct` is the one that matters: its proofs assert process survival, not just
return values — a crashed tool must not kill the session, a hanging tool must time
out, a cancelled run must really stop its active tool call.

## Drive a run in the shell

Open an interactive runtime shell and start a session and a run:

```bash
rebar3 shell
```

The canonical demo is a three-step run — `file_read → echo → file_write` — wired
so each step feeds the next through `from_step`. It exercises the whole tree:
a long-lived session, a per-run `gen_statem`, and a disposable per-tool-call
worker, with every step emitting events into the store.

## Where to go next

Read **Overview** for the mental model, then the Concepts pages for the
supervision tree, tools, steps, and the event trail.
