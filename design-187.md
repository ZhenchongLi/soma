# docs: document actor stable names and crash reasons

## Current state

Two runtime behaviors are already built and merged, but the docs still describe
the old world.

Stable-name actor addressing exists in code:

- `soma_actor_sup:start_actor/1` accepts a `stable_name` option. When the started
  actor's `init/1` sees `stable_name` (a binary), it calls
  `soma_actor_registry:register(StableName, self())`.
- `soma_actor_registry` is a `gen_server` started under `soma_actor_sup` (a
  `permanent` worker child, `local` name `soma_actor_registry`). It holds a
  `binary name => pid` map. `lookup/1` returns `{ok, Pid}` only if the pid is
  still alive, otherwise `{error, not_found}`; an unknown name is also
  `{error, not_found}`.
- `soma_actor:send/2` resolves its first argument through `resolve_actor_ref/1`.
  A binary goes to `soma_actor_registry:lookup/1`. A pid passes straight through.
  So `send/2` accepts either a binary stable name or a pid, and a lookup miss
  bubbles up as `{error, not_found}`.
- An `actor_message` proposal (`soma_proposal:normalize/1`) accepts a `to` field
  that is a pid or a binary. On delivery the actor hands `to` to
  `soma_actor:send/2`, so a binary `to` is a stable name. A delivery to an
  unknown/dead target exits the inner `gen_statem:call`; the actor catches that,
  marks the sender's task `failed`, and the sender actor stays alive.

The crash-reason fix exists in code:

- `soma_tool_call:start/1` spawns its worker with `spawn_monitor`. If the tool
  crashes immediately, the run learns the real exit reason from the monitor's
  `'DOWN'`, not a `noproc`. (A plain `spawn` followed by a separate `monitor`
  can race: the process can already be dead when `monitor` runs, and the monitor
  then fires `noproc` instead of the real reason. `spawn_monitor` sets up the
  monitor atomically at spawn, so the real reason always arrives.)

What the docs say today:

- `docs/usage.md` shows actor targets only as pids (`{ok, Actor} = ...start_actor(...)`,
  then `soma_actor:send(Actor, Env)`). No `stable_name`, no registry, no binary
  target, no `{error, not_found}`.
- `docs/zh/soma-actor.zh.md` uses `ActorPid` everywhere. The `actor identity`
  line mentions `registry entry` in passing but never documents `stable_name`,
  binary targets, or the `{error, not_found}` miss.
- `CLAUDE.md` describes the actor without naming `soma_actor_registry`, and
  describes `soma_tool_call` without naming `spawn_monitor` or the crash-reason
  behavior.

## Approach

Docs-only. Describe the behavior that already ships. No code, no runtime change.

Three files change:

- `docs/usage.md` — add a section on stable-name actor addressing under the
  advanced-actor material. Cover the `stable_name` start option, the registry,
  binary targets for `send/2` and for `actor_message.to`, the `{error, not_found}`
  cases (unknown name, dead registered pid), same-name restart replacing the
  entry, and the note that pid addressing still works.
- `docs/zh/soma-actor.zh.md` — a Chinese section covering the three points the
  issue calls out in Chinese: `stable_name` as a start option, binary names as
  accepted targets, and unknown names returning `{error, not_found}`.
- `CLAUDE.md` — extend the actor description to name `soma_actor_registry` as the
  stable-name mechanism, and extend the `soma_tool_call` description to name
  `spawn_monitor` and say immediate crashes keep the real exit reason instead of
  `noproc`.

Each of the 15 criteria is proved the way this repo already proves doc content:
an EUnit test that reads the target file and asserts the needed substrings are
present. There is already a family of these (`soma_usage_docs_tests`,
`soma_usage_tracing_doc_tests`, `soma_l4_contract_doc_tests`, and so on), so I
follow that pattern rather than inventing a new one.

I plan two new test modules:

- `apps/soma_actor/test/soma_actor_naming_docs_tests.erl` — reads `docs/usage.md`
  and `docs/zh/soma-actor.zh.md`, proves the actor-naming criteria (1–13).
- `apps/soma_actor/test/soma_crash_reason_docs_tests.erl` — reads `CLAUDE.md`,
  proves the `CLAUDE.md` criteria (10, 14, 15).

Criterion 10 lives in `CLAUDE.md` but is about the registry, so it can sit in
either module; I keep it in the crash-reason module because both read `CLAUDE.md`.
This is a naming choice, not a behavior one.

The path helper mirrors `soma_usage_docs_tests`: `code:lib_dir(soma_actor)` then
up to the repo root, then into `docs/` or the root file. Each check is a
`binary:match/2` substring assertion. The load-bearing part of each test is the
exact substring, so the design lists the substring per criterion below.

## Acceptance criteria → tests

### Criterion 1 — `stable_name` is a `start_actor/1` option
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it names `stable_name` as a
  `soma_actor_sup:start_actor/1` option (substrings `stable_name` and
  `start_actor`)
- Test: `test_usage_documents_stable_name_start_option` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 2 — `soma_actor_registry` is the supervised name registry
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it names `soma_actor_registry` as
  the binary-name registry supervised under `soma_actor_sup` (substrings
  `soma_actor_registry` and `soma_actor_sup`)
- Test: `test_usage_documents_registry_under_sup` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 3 — `send/2` accepts a binary stable name as `ActorRef`
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it states `soma_actor:send/2`
  accepts a binary stable name as the actor reference (substrings
  `soma_actor:send` and `stable name` near `send`)
- Test: `test_usage_documents_send_accepts_stable_name` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 4 — unknown stable name makes `send/2` return `{error, not_found}`
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it states an unknown stable name
  makes `send/2` return `{error, not_found}` (substring `{error, not_found}`
  in the send/unknown-name context)
- Test: `test_usage_documents_send_unknown_name_not_found` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 5 — binary stable names are valid `actor_message.to` values
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it lists binary stable names as
  valid `actor_message.to` values (substring `actor_message.to` with the
  stable-name statement)
- Test: `test_usage_documents_actor_message_to_stable_name` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 6 — unknown `actor_message.to` is a sender-task failure, sender alive
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it describes an unknown
  `actor_message.to` as a delivery failure that fails the sender's task while
  the sender actor stays alive (substrings covering "sender task" failure and
  the sender staying alive)
- Test: `test_usage_documents_unknown_to_fails_sender_task` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 7 — same-name restart replaces the registry entry
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it documents that a same-name actor
  restart replaces the registry entry (substrings for "same name" and "replace"
  the entry)
- Test: `test_usage_documents_same_name_restart_replaces_entry` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 8 — lookup of a dead registered pid returns `{error, not_found}`
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it states that looking up a dead
  registered pid returns `{error, not_found}` (substrings for "dead" pid and
  `{error, not_found}`)
- Test: `test_usage_documents_dead_pid_lookup_not_found` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 9 — pid-based addressing remains supported
- Call chain: none (direct source-file read)
- Test entry: reads `docs/usage.md`, asserts it states pid-based actor
  addressing is still supported (substring stating a pid is still an accepted
  actor reference)
- Test: `test_usage_documents_pid_addressing_still_supported` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 10 — `CLAUDE.md` names `soma_actor_registry` as the stable-name mechanism
- Call chain: none (direct source-file read)
- Test entry: reads `CLAUDE.md`, asserts the actor description names
  `soma_actor_registry` as the stable-name addressing mechanism (substrings
  `soma_actor_registry` and `stable`)
- Test: `test_claude_md_names_actor_registry` in `apps/soma_actor/test/soma_crash_reason_docs_tests.erl`

### Criterion 11 — zh doc documents `stable_name` as a start option (Chinese)
- Call chain: none (direct source-file read)
- Test entry: reads `docs/zh/soma-actor.zh.md`, asserts it documents
  `stable_name` as an actor start option in Chinese (substring `stable_name`
  plus a Chinese start-option phrase such as 启动选项)
- Test: `test_zh_documents_stable_name_start_option` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 12 — zh doc states binary names are accepted targets (Chinese)
- Call chain: none (direct source-file read)
- Test entry: reads `docs/zh/soma-actor.zh.md`, asserts it states binary stable
  names are accepted actor targets in Chinese (substring for binary name plus a
  Chinese target phrase such as 目标)
- Test: `test_zh_documents_binary_name_target` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 13 — zh doc states unknown names return `{error, not_found}` (Chinese)
- Call chain: none (direct source-file read)
- Test entry: reads `docs/zh/soma-actor.zh.md`, asserts it states unknown stable
  names return `{error, not_found}` in Chinese (substring `{error, not_found}`
  with a Chinese unknown-name phrase)
- Test: `test_zh_documents_unknown_name_not_found` in `apps/soma_actor/test/soma_actor_naming_docs_tests.erl`

### Criterion 14 — `CLAUDE.md` names `spawn_monitor` as the worker-spawn mechanism
- Call chain: none (direct source-file read)
- Test entry: reads `CLAUDE.md`, asserts the `soma_tool_call:start/1`
  description names `spawn_monitor` (substrings `spawn_monitor` and
  `soma_tool_call`)
- Test: `test_claude_md_names_spawn_monitor` in `apps/soma_actor/test/soma_crash_reason_docs_tests.erl`

### Criterion 15 — `CLAUDE.md` says immediate crashes keep the real reason, not `noproc`
- Call chain: none (direct source-file read)
- Test entry: reads `CLAUDE.md`, asserts it states an immediate tool crash keeps
  the real exit reason instead of `noproc` (substrings for "real exit reason"
  and `noproc`)
- Test: `test_claude_md_immediate_crash_keeps_real_reason` in `apps/soma_actor/test/soma_crash_reason_docs_tests.erl`

## Risks & trade-offs

Substring tests prove a string is present, not that the surrounding prose is
correct or readable. A test passes even if the sentence around the substring is
wrong. That is the accepted cost of doc-content tests in this repo, and the
review of the prose catches what the test cannot. I keep the asserted substrings
short and behavior-specific (`{error, not_found}`, `stable_name`, `spawn_monitor`)
so a passing test still means the concrete term is documented, not just a vague
mention.

The Chinese-doc criteria assert Chinese phrases. Chinese phrasing has more than
one natural wording, so the test pins a specific phrase and the doc must use that
exact phrase. Dev should pick the phrase when writing the doc and the test
together, so they cannot drift. This is the normal shape of the existing Chinese
doc tests in the repo.
