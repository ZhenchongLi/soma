---
title: Resume
description: Read-only reconstruction of run progress from the durable event trail.
---

The first persistent-resume slice makes the durable event trail sufficient to
reconstruct run progress after a restart.

:::caution
This is **read-only reconstruction, not resumed execution.** Reconstruction
rebuilds what a run had done from its events; it never starts a resumed run,
never re-runs a tool, and never appends an event. Starting a resumed run is a
later slice.
:::

## Journaling the run

`soma_run:init/1` journals the run into `run.started` as
`#{steps, run_options}`, where `run_options` is an allowlist of resume-safe
metadata: `run_id`, an optional `session_id`, and an optional `correlation_id`.
It never journals process-local values (`session_pid`, the event store, pids,
monitor refs, timers, OS pids) or secrets.

## Reconstructing progress

`soma_run_resume:reconstruct/2` reads `soma_event_store:by_run/2` and rebuilds
`#{run_id, steps, run_options, outputs, next_step, terminal_status}`:

- committed `step.succeeded` outputs keyed by step id;
- the first uncommitted journal step as `next_step` — a progress marker, **not**
  a resume permission;
- the terminal status (`completed` / `failed` / `timeout` / `cancelled`, else
  `undefined`) when a terminal event is present.

```erlang
%% Pure read: reconstruct progress, never start or mutate a run.
{ok, Progress} = soma_run_resume:reconstruct(Store, RunId).
```

It rejects a trail with no usable `run.started` journal
(`{error, no_run_started_journal}`) or one whose committed step id is absent
from the journal (`{error, {unknown_committed_step, _}}`), and is strictly
side-effect-free — it never appends events and never starts a run child.
