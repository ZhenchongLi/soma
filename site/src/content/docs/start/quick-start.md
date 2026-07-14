---
title: Quick start
description: Run Soma through the packaged CLI and Soma Lisp task files.
---

Soma's public edge is the `soma` command plus Soma Lisp task files. The first
client command auto-starts the local daemon; you do not need a separate server
ritual.

## Get the command

From a release, put `bin/soma` on your `PATH`. From this checkout, build the
local release once:

```bash
rebar3 release
SOMA="_build/default/rel/somad/bin/soma"
```

## Run a task

A Soma Lisp task is the public source form for `soma run`. This one reads a file,
passes the bytes through `echo`, and writes the result back out:

```bash
mkdir -p /tmp/soma-demo
printf 'hi soma\n' > /tmp/soma-demo/input.txt

cat > /tmp/soma-demo/pipeline.lisp <<'EOF'
(task
  (let* ((read (tool file_read
                 (path "input.txt")
                 (root "/tmp/soma-demo")))
         (process (tool echo
                    (from read)))
         (write (tool file_write
                  (path "output.txt")
                  (root "/tmp/soma-demo")
                  (bytes (from process)))))
    (return write)))
EOF

$SOMA run /tmp/soma-demo/pipeline.lisp
cat /tmp/soma-demo/output.txt
```

The CLI prints a Lisp `(result ...)` with a `task-id` and `correlation-id`.
Use the task id for `status` / `cancel`; use the correlation id for `trace`:

```bash
$SOMA trace "<correlation-id-from-result>"
$SOMA status "<task-id-from-result>"
$SOMA stop
```

## Ask

`soma ask "..."` drives the actor decision path through the same daemon. It needs
`~/.soma/config` plus `SOMA_LLM_API_KEY`; deterministic `soma run` task files need
no model.

## Where to go next

Read the **LFE DSL** guide for task syntax, then the CLI guide for `run`,
`ask`, `status`, `trace`, `cancel`, detached tasks, and daemon configuration.
