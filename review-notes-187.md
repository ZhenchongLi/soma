### Claude

## Verdict
approve

## Real issues
None.

## Questions
None.

## Nits
- `docs/usage.md` shows `{ok, <<"t2">>} = soma_actor:send(<<"worker">>, Env).` as the success return. That's a `task_id` binary, fine, but the section never says what the binary is. A one-word "(the minted task id)" would save a reader a trip to the source. Not blocking.

## Functional evidence
- Criterion 1 — pass: `docs/usage.md` "Advanced: stable-name actor addressing" — `soma_actor_sup:start_actor/1` accepts an optional `stable_name` option, shown in the code block with `stable_name => <<"worker">>`. Matches `soma_actor_sup:start_actor/1` + `soma_actor:maybe_register_stable_name/1`.
- Criterion 2 — pass: `docs/usage.md` "The binary-name registry is `soma_actor_registry`, a supervised worker started under `soma_actor_sup`." Matches `soma_actor_sup.erl` child spec `#{id => soma_actor_registry, start => {soma_actor_registry, start_link, []}}`.
- Criterion 3 — pass: `docs/usage.md` "`soma_actor:send/2` accepts a binary stable name as its `ActorRef`". Matches `soma_actor:resolve_actor_ref/1` binary clause → `soma_actor_registry:lookup/1`.
- Criterion 4 — pass: `docs/usage.md` "`soma_actor:send/2` returns `{error, not_found}`" for an unknown name, with `{error, not_found} = soma_actor:send(<<"no-such-name">>, Env).`. Matches `soma_actor_registry:lookup/1` `error -> {error, not_found}`.
- Criterion 5 — pass: `docs/usage.md` "its `to` field may be a binary stable name (not just a pid)". Matches `soma_proposal:normalize/1` `actor_message` clauses guarded `is_binary(To)`.
- Criterion 6 — pass: `docs/usage.md` "delivery is a failure that fails the sender's task, but the sender actor stays alive." Matches `soma_actor:execute_actor_message/5` — `{error, not_found}` → `fail_task` → `keep_state` (sender survives).
- Criterion 7 — pass: `docs/usage.md` "the new actor registers its own pid under that name and replaces the registry entry". Matches `soma_actor_registry` `maps:put/3` (last-writer-wins).
- Criterion 8 — pass: `docs/usage.md` "looking that name up returns `{error, not_found}` rather than a stale pid." Matches `soma_actor_registry:handle_call/3` `is_process_alive(Pid)` false → `{error, not_found}`.
- Criterion 9 — pass: `docs/usage.md` "pid-based actor addressing remains supported. A pid is still an accepted `ActorRef`". Matches `soma_actor:resolve_actor_ref/1` pid pass-through clause.
- Criterion 10 — pass: `CLAUDE.md` actor description "**Stable-name addressing** goes through `soma_actor_registry` — a `gen_server` supervised under `soma_actor_sup`".
- Criterion 11 — pass: `docs/zh/soma-actor.zh.md` "稳定名寻址" section — "`soma_actor_sup:start_actor/1` 接受 `stable_name` 这个**启动选项**". Test `zh_documents_stable_name_start_option_test` green.
- Criterion 12 — pass: `docs/zh/soma-actor.zh.md` "**二进制稳定名是被接受的 actor 寻址目标**". Test `zh_documents_binary_name_target_test` green.
- Criterion 13 — pass: `docs/zh/soma-actor.zh.md` "找不到的名字解析为 `{error, not_found}`". Test `zh_documents_unknown_name_not_found_test` green.
- Criterion 14 — pass: `CLAUDE.md` "`soma_run` spawns it through `soma_tool_call:start/1`, which uses `spawn_monitor`". Matches `soma_tool_call:start/1` `spawn_monitor(fun() -> run(Opts) end)`.
- Criterion 15 — pass: `CLAUDE.md` "an immediate tool crash keeps the real exit reason in the `'DOWN'` instead of collapsing to `noproc`". Matches the atomic-monitor rationale of `spawn_monitor` in `soma_tool_call:start/1`.

All 15 doc-content proofs green: `rebar3 eunit --module=soma_actor_naming_docs_tests,soma_crash_reason_docs_tests` → 15 tests, 0 failures.
