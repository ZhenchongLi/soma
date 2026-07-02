# [cc] cli argv placeholders for multi-arg external tools

## Current state

The `cli` adapter is shell-free today. `soma_tool_call:run_cli/5` opens an Erlang port with `{spawn_executable, Executable}` and passes `{args, Args}`. Static `argv` entries are rendered as literal port args, then the resolved step input is always appended as one final arg.

That shape works for tools that accept one dynamic payload. It does not work for CLIs that need dynamic values in more than one argv slot, such as `edit <doc> <changes>`.

`soma_tool_manifest:normalize/1` validates shared manifest fields, `description`, and `params`. For `cli`, it only checks that `argv` is a list. It does not inspect `"{name}"` placeholders or prove that a placeholder is declared in `params`.

`soma_tool_config:load_dir/1` compiles `(tool ...)` files into manifest maps and then calls `soma_tool_registry:register_tool/1`. That already sends config tools through `normalize/1`, so placeholder validation belongs in the manifest normalizer, not in the config loader.

`soma_run` resolves `from_step` values before it starts the tool-call worker. It emits `step.started`, resolves the descriptor, and then starts `soma_tool_call`. That is the right owner for missing placeholder detection because the acceptance criteria require the failure before any `tool.started` event.

The actor path starts owned runs with `session_pid => self()`. A run failure already becomes `actor.task.failed` data and the actor stays alive. A placeholder failure should use that same run-failure path.

## Approach

Add whole-argument placeholders to `cli` descriptors. A placeholder is an argv element whose full text is `"{name}"`. It is not substring interpolation. The name inside the braces must match a declared `params` entry by binary name.

Keep `argv` storage stable. `normalize/1` should preserve the literal placeholder string or binary in the normalized descriptor. The descriptor remains readable and config-loaded tools do not gain a second compiled template field.

Validate placeholders in `soma_tool_manifest:normalize/1` after params validation and before `normalize_complete/1`. For `cli` manifests, collect placeholder names from `argv`. Reject the first placeholder with no matching param as `{error, {unknown_argv_placeholder, Name}}`. This gives config loading the same named reason because `soma_tool_config` already reports register/normalize errors unchanged.

At runtime, keep no-placeholder behavior byte-for-byte: `executable argv... <input>` still appends the rendered resolved input as the final arg.

For a descriptor with placeholders, render a complete argv before starting the worker. Add a small CLI-preparation step in `soma_run` after descriptor resolution and before `soma_tool_call:start/1`. It should:

- build a lookup map from the resolved step args.
- accept atom or binary step arg keys without creating atoms.
- replace each `"{name}"` argv entry with the rendered value from the lookup.
- fail with `{missing_cli_placeholder, Name}` if the key is absent.
- fail before `soma_tool_call:start/1`, so no `tool.started` event can exist.
- mark the worker opts so `soma_tool_call` does not append the trailing rendered input.

For atom or binary arg keys, normalize lookup by converting atom keys with `atom_to_binary(Key, utf8)`. Do not call `binary_to_atom/2` or `list_to_atom/1` for placeholder lookup.

Use the declared param type for rendering:

- `string`: binary becomes a string arg, and an Erlang string stays literal.
- `integer`: integer becomes base-10 decimal text.
- `boolean`: `true` becomes `"true"` and `false` becomes `"false"`.

If a value does not match its declared type, fail before worker start with `{invalid_cli_placeholder_value, Name, Type}`. This is not named in the acceptance criteria, but it prevents a typed placeholder from silently falling back to Erlang term printing.

The existing worker still owns port execution, OS pid reporting, output collection, timeout teardown, and cancel teardown. The run only prepares the argv vector and chooses whether trailing input is appended.

Docs should describe the new syntax as an additive CLI manifest feature. They should also state that manifests with no placeholders keep the old final-input behavior.

## Acceptance criteria → tests

### Criterion 1 — normalize preserves a declared argv placeholder
- Call chain: none (pure manifest normalization)
- Test entry: `soma_tool_manifest:normalize/1`
- Code boundary: `apps/soma_tools/src/soma_tool_manifest.erl`
- Responsibility owner: `soma_tools` owns manifest validation and normalized descriptor shape.
- Test: `test_normalize_preserves_cli_argv_placeholder_with_declared_param` in `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 2 — normalize rejects an undeclared argv placeholder
- Call chain: none (pure manifest normalization)
- Test entry: `soma_tool_manifest:normalize/1`
- Code boundary: `apps/soma_tools/src/soma_tool_manifest.erl`
- Responsibility owner: `soma_tools` owns fail-closed manifest validation.
- Test: `test_normalize_rejects_cli_argv_placeholder_without_param` in `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 3 — config loader registers a templated cli tool
- Call chain: daemon boot -> `soma_tool_config:load_dir/1` -> `soma_tool_registry:register_tool/1` -> `soma_tool_manifest:normalize/1`
- Test entry: `soma_tool_config:load_dir/1`
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` and `apps/soma_tools/src/soma_tool_manifest.erl`
- Responsibility owner: `soma_actor` owns config file compilation, while `soma_tools` owns manifest validity.
- Test: `test_load_dir_registers_cli_tool_with_argv_placeholders` in `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 4 — config loader skips an undeclared placeholder
- Call chain: daemon boot -> `soma_tool_config:load_dir/1` -> `soma_tool_registry:register_tool/1` -> `soma_tool_manifest:normalize/1`
- Test entry: `soma_tool_config:load_dir/1`
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` and `apps/soma_tools/src/soma_tool_manifest.erl`
- Responsibility owner: `soma_actor` owns skip reporting, while `soma_tools` owns the named placeholder error.
- Test: `test_load_dir_skips_cli_tool_with_unknown_argv_placeholder` in `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 5 — cli run replaces doc placeholder from a prior step
- Call chain: `soma_agent_session:start_run/2` -> `soma_run:executing/3` -> `soma_tool_registry:resolve_descriptor/1` -> `soma_run` placeholder preparation -> `soma_tool_call:start/1` -> `soma_tool_call:run_cli/5`
- Test entry: `soma_agent_session:start_run/2`
- Code boundary: `apps/soma_runtime/src/soma_run.erl` and `apps/soma_runtime/src/soma_tool_call.erl`
- Responsibility owner: `soma_runtime` owns from-step resolution, argv rendering, worker start, and port execution.
- Test: `test_cli_argv_placeholder_from_step_replaces_doc` in `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`

### Criterion 6 — templated cli run appends no trailing input
- Call chain: `soma_agent_session:start_run/2` -> `soma_run:executing/3` -> `soma_run` placeholder preparation -> `soma_tool_call:start/1` -> `soma_tool_call:run_cli/5`
- Test entry: `soma_agent_session:start_run/2`
- Code boundary: `apps/soma_runtime/src/soma_run.erl` and `apps/soma_runtime/src/soma_tool_call.erl`
- Responsibility owner: `soma_runtime` owns the compatibility split between templated argv and no-placeholder argv.
- Test: `test_cli_argv_placeholder_sends_no_trailing_input` in `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`

### Criterion 7 — placeholder metacharacters remain one argv element
- Call chain: `soma_agent_session:start_run/2` -> `soma_run:executing/3` -> `soma_run` placeholder preparation -> `soma_tool_call:start/1` -> `soma_tool_call:run_cli/5` -> `open_port/2`
- Test entry: `soma_agent_session:start_run/2`
- Code boundary: `apps/soma_runtime/src/soma_run.erl` and `apps/soma_runtime/src/soma_tool_call.erl`
- Responsibility owner: `soma_runtime` owns shell-free argv construction.
- Test: `test_cli_argv_placeholder_metacharacters_are_one_arg` in `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`

### Criterion 8 — placeholders render by declared param type
- Call chain: `soma_agent_session:start_run/2` -> `soma_run:executing/3` -> `soma_run` placeholder preparation -> `soma_tool_call:start/1` -> `soma_tool_call:run_cli/5`
- Test entry: `soma_agent_session:start_run/2`
- Code boundary: `apps/soma_runtime/src/soma_run.erl`
- Responsibility owner: `soma_runtime` owns runtime value rendering from normalized descriptor metadata.
- Test: `test_cli_argv_placeholder_renders_string_integer_boolean` in `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`

### Criterion 9 — missing placeholder key fails before tool.started
- Call chain: `soma_agent_session:start_run/2` -> `soma_run:executing/3` -> `soma_tool_registry:resolve_descriptor/1` -> `soma_run` placeholder preparation -> `run.failed`
- Test entry: `soma_agent_session:start_run/2`
- Code boundary: `apps/soma_runtime/src/soma_run.erl`
- Responsibility owner: `soma_runtime` owns pre-worker validation for step data.
- Test: `test_cli_argv_placeholder_missing_key_fails_before_tool_started` in `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`

### Criterion 10 — session completes a later run after missing placeholder
- Call chain: `soma_agent_session:start_run/2` -> first `soma_run` fails before worker start -> same `soma_agent_session:start_run/2` -> second `soma_run` completes
- Test entry: `soma_agent_session:start_run/2`
- Code boundary: `apps/soma_runtime/src/soma_run.erl` and `apps/soma_runtime/src/soma_agent_session.erl`
- Responsibility owner: `soma_runtime` owns run failure as session data.
- Test: `test_session_alive_runs_new_run_after_cli_placeholder_missing_key` in `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`

### Criterion 11 — actor remains alive after missing placeholder task failure
- Call chain: `soma_actor:send/2` -> `soma_actor:maybe_start_run/4` -> `soma_run:start_link/1` -> `soma_run` placeholder preparation -> `{run_failed, RunId, Reason}` -> `actor.task.failed`
- Test entry: `soma_actor:send/2`
- Code boundary: `apps/soma_actor/src/soma_actor.erl` and `apps/soma_runtime/src/soma_run.erl`
- Responsibility owner: `soma_actor` owns task status and actor survival. `soma_runtime` owns the missing-placeholder run failure.
- Test: `cli_placeholder_missing_key_marks_task_failed_actor_alive` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 12 — runtime placeholder tests use repo-created stubs
- Call chain: none (direct source-file read)
- Test entry: direct read of `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`
- Code boundary: `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`
- Responsibility owner: `soma_runtime` tests own their helper executable fixtures.
- Test: `test_placeholder_runtime_tests_use_repo_created_stub_executables` in `apps/soma_runtime/test/soma_cli_placeholder_marker_tests.erl`

### Criterion 13 — tool manifest docs describe placeholders
- Call chain: none (direct source-file read)
- Test entry: direct read of `docs/tool-manifest.md`
- Code boundary: `docs/tool-manifest.md`
- Responsibility owner: documentation owns public manifest syntax and failure behavior.
- Test: `test_tool_manifest_docs_describe_cli_argv_placeholders` in `apps/soma_tools/test/soma_tool_manifest_doc_tests.erl`

### Criterion 14 — v0.2 contract maps new manifest and runtime proofs
- Call chain: none (direct source-file read)
- Test entry: direct read of `docs/contracts/v0.2-test-contract.md`
- Code boundary: `docs/contracts/v0.2-test-contract.md`
- Responsibility owner: v0.2 contract docs own manifest and CLI runtime proof mapping.
- Test: `test_v0_2_contract_maps_cli_argv_placeholder_proofs` in `apps/soma_runtime/test/soma_v0_2_contract_tests.erl`

### Criterion 15 — tool-config contract maps config proof
- Call chain: none (direct source-file read)
- Test entry: direct read of `docs/contracts/tool-config-test-contract.md`
- Code boundary: `docs/contracts/tool-config-test-contract.md`
- Responsibility owner: tool-config contract docs own config-loader proof mapping.
- Test: `test_tool_config_contract_maps_cli_argv_placeholder_proofs` in `apps/soma_actor/test/soma_tool_config_contract_tests.erl`

## Risks & trade-offs

Whole-argument placeholders are less flexible than substring interpolation. That is intentional. It keeps argv construction shell-free and avoids quoting rules.

Rendering typed placeholders before worker start moves some CLI adapter logic into `soma_run`. The upside is that missing keys fail before `tool.started`, which the issue requires. The worker still owns the external process.

Supporting atom and binary step arg keys makes runtime tests and Lisp-compiled steps practical. The implementation must not create atoms from placeholder names.

No-placeholder compatibility is important. A descriptor with no placeholders must still receive the old trailing input arg.

The direct source-read tests for docs and test fixture policy can drift if file names change. Keep them narrow and tied to the exact contract rows this issue adds.
