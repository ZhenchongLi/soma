---
title: Events and trace
description: The mandatory event stream and the read-side trace tooling over it.
---

Events are mandatory from day one. Every session, run, and tool call emits
events into `soma_event_store`, and the event stream is the system's record of
what happened.

## Every event carries the same fields

Every event carries `event_id`, `timestamp`, `session_id`, `run_id`, `step_id`,
`tool_call_id`, `event_type`, and `payload`. The event types span the whole
lifecycle, from `session.started` through `run.timeout`, plus the actor and
decision events (`actor.*`, `proposal.*`, `llm.*`).

## Querying by correlation

The store exposes `by_*` queries. Because every event in one task chain carries
the same `correlation_id`, `soma_event_store:by_correlation/2` returns the full
chain for that task — the actor envelope, the decision, the run, and every tool
call.

```erlang
%% Pull the whole chain for one task, then render it as a timeline.
Events = soma_event_store:by_correlation(Store, CorrelationId),
io:format("~ts~n", [soma_trace:timeline(Events)]).
```

## Trace tooling

`soma_trace` is read-side trace tooling that depends on nothing above
`soma_event_store`. `soma_trace:timeline/1` is pure — it renders a list of
event maps as a readable, timestamp-ordered timeline, one line per event.
`soma_trace:render/2` is `by_correlation/2` followed by `timeline/1`. It is
read-only and never writes events.
