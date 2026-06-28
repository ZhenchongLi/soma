---
title: Steps
description: The small sequential step-list format the runtime executes.
---

Soma uses a deliberately small step-list format — not an intermediate
representation yet. A step list is a list of maps, and the executor is strictly
sequential. The runtime must not depend on where steps came from: every future
planner (the LFE DSL, an LLM planner) compiles down to exactly this format.

## The step-list format

A step is a map with `id`, `tool`, `args`, and `timeout_ms`. The `args` may
reference the output of a prior step with a simple `from_step` reference.

```erlang
[
  #{id => read,  tool => file_read, args => #{path => <<"in.txt">>}, timeout_ms => 1000},
  #{id => up,    tool => echo,      args => #{from_step => read},     timeout_ms => 1000},
  #{id => write, tool => file_write, args => #{path => <<"out.txt">>, from_step => up}, timeout_ms => 1000}
]
```

The demo run that proves the v0.1 contract is exactly this shape:
`file_read → echo → file_write`.

## from_step wiring

The only data flow between steps is the `from_step` reference. When a step's
`args` carry `from_step => SomePriorId`, the runtime substitutes the recorded
output of that prior step. This is the whole variable model — there are no named
variables, no expressions.

## What is deliberately out of scope

The executor is sequential: validate the step, start the tool call, wait for the
result, record the event, advance to the next step. There is no branching, no
loops, no DAG, no variables beyond `from_step`. Parallelism and richer planning
are roadmap items that still compile down to this same list.
