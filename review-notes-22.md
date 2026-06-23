### Claude

## Verdict
approve

## Real issues
None.

## Questions
- Criterion 3 says the executable is "resolved at runtime from code:priv_dir/1". The CT resolves `code:priv_dir(soma_tools)` in the test body and stores the resulting absolute string in the manifest's `executable`. So resolution happens at registration time in the test, not at invocation time inside the adapter. The design names this and the criterion's wording ("resolved at runtime from code:priv_dir/1, not an absolute build path") is met — the path is computed from `priv_dir`, never typed in. Flagging only so a future real CLI tool resolves `priv_dir` in its own `describe/0` or registration helper rather than copying an absolute string from somewhere else.

## Nits
- `docs/release.md` carries two smoke tests under similar headings (the booted-release echo run at line 44, the helper run at line 79). A reader skimming for "the smoke test" hits the echo one first. A one-line pointer from the top smoke section to the helper smoke command would save the round trip.

## Functional evidence
- Criterion 1 — pass: `apps/soma_tools/priv/cli/soma_sample_upper` committed, git mode 100755 (`git ls-files -s` shows `100755 ... soma_sample_upper`). Asserted by `sample_helper_committed_and_executable_test` checking owner-execute bit.
- Criterion 2 — pass: helper first line is `#!/bin/sh`, no `escript` and no `%%!` header. Asserted by `sample_helper_is_shell_script_not_escript_test`. Ran `soma_sample_upper hello` directly from zsh → `HELLO`, exit 0, no Erlang in the call path.
- Criterion 3 — pass: `test_priv_helper_run_reaches_completed_with_stdout` resolves `code:priv_dir(soma_tools)`, registers it as cli tool `sample_upper`, drives a run through `soma_agent_session:start_run`, asserts `run.completed` in the event types and the recorded step output equals the uppercased adapter rendering of the input. Green in `rebar3 ct` (soma_cli_packaging_SUITE 2/2).
- Criterion 4 — pass: `test_priv_helper_resolvable_and_runnable_in_place` asserts the resolved path's basename is `priv`, the helper file exists there, and a direct `open_port({spawn_executable, ...})` returns `<<"HELLO">>`. Green in `rebar3 ct`.
- Criterion 5 — pass: `docs/release.md` lines 64-72 name `lib/soma_tools-<vsn>/priv/...` and the full `lib/soma_tools-<vsn>/priv/cli/soma_sample_upper`. Asserted by `release_doc_states_priv_location_test`.
- Criterion 6 — pass: `docs/release.md` lines 85-100 document naming by `code:priv_dir/1` and contrast it against an "absolute build path". Asserted by `release_doc_states_priv_dir_convention_test`.
- Criterion 7 — pass: `docs/release.md` lines 102-113 name macOS arm64, Linux x86_64, Linux arm64 and state a build carries "only that architecture's helper". Asserted by `release_doc_states_per_architecture_rule_test`.
- Criterion 8 — pass: `docs/release.md` line 79 `_build/prod/rel/soma/lib/soma_tools-0.1.0/priv/cli/soma_sample_upper hello`, expect `HELLO`. Asserted by `release_doc_has_helper_smoke_command_test`.
- Criterion 9 — pass: `rebar3 eunit` → 54 tests, 0 failures. `rebar3 ct` → all 61 tests passed, existing soma_cli_adapter/failure/lifecycle and soma_run suites green.
