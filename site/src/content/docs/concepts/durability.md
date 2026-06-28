---
title: Durability
description: Opt-in disk_log persistence and the rebuildable in-memory index.
---

The event stream is made durable behind the same `by_*` query API. The
principle this establishes is the foundation for resume: **the durable log is
the source of truth, and the in-memory index is a rebuildable cache.**

## Opt-in disk_log persistence

`soma_event_store` gained opt-in persistence backed by `disk_log`. Calling
`start_link/1` with `#{log => Path}` opens a `halt` `disk_log`; `append/2`
writes the normalized event to the log *and* the in-memory index; and `init/1`
replays the log on boot to rebuild the index, tolerating a truncated tail.

```erlang
%% Durable: events survive a BEAM restart by replaying the disk_log on boot.
{ok, Store} = soma_event_store:start_link(#{log => "/var/soma/events.log"}).

%% In-memory default, byte for byte the same behaviour minus persistence.
{ok, Store} = soma_event_store:start_link().
```

`start_link/0` stays purely in-memory, so events survive a BEAM restart only on
the persistent path.

## Wiring it in production

`soma_sup` chooses the store's backing through app env —
`application:get_env(soma_runtime, event_store_log, undefined)`. A path routes
to `start_link/1` (durable); leaving it unset routes to `start_link/0` (the
in-memory default for development and tests). The production release becomes
durable simply by setting the env in `sys.config`.

```bash
# Setting the event_store_log env makes the release durable.
SOMA_EVENT_STORE_LOG=/var/soma/events.log
```
