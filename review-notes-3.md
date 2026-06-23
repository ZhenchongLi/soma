### Claude

## Verdict
approve

## Real issues
None.

## Questions

- `soma_tool_fail:invoke/2` has clauses only for `mode => crash` and `mode => error`. Any other input (or no `mode` key) raises `function_clause`. For a test-only tool that's arguably fine — but is that the intended third behavior, or should an unknown mode return a clean `{error, _}`? The execution-core issue will route every tool the same way; decide before it depends on this.
- `filelib:safe_relative_path/2` rejects *all* absolute paths, including one that legitimately points under the root (verified: `safe_relative_path(<<"/tmp/root/sub/x">>, "/tmp/root")` returns `unsafe`). So the file tools accept relative paths only. That matches v0.1 steps using relative `from_step` references, but it's stricter than "absolute outside the root is rejected." Confirm tools are never expected to take an absolute in-root path.
- The roundtrip test asserts `{ok, Bytes}` from read but only `{ok, _}` from write — write returns `{ok, byte_size(Bytes)}`. The byte-count return shape isn't pinned by any test. Intentional, or should write's output shape be asserted before the run records it as a step result?

## Nits

- `soma_tool_file_read`/`file_write` rewrap `file:read_file`/`write_file` results (`{ok, B} -> {ok, B}`, `{error, R} -> {error, R}`). The match is a pass-through. Harmless, drop it if you want fewer lines.
- `soma_tool.erl` types `input/0`, `output/0`, `error/0` are all `term()` — fine as placeholders, but they carry no information for dialyzer yet.

## Functional evidence
- Criterion 1 — pass: `soma_tool.erl` declares `-callback describe() -> spec()` and `-callback invoke(input(), ctx()) -> {ok, output()} | {error, error()}`. Test `behaviour_declares_callbacks_test` asserts `behaviour_info(callbacks)` lists `{describe,0}` and `{invoke,2}`. 21/21 eunit pass.
- Criterion 2 — pass: `soma_tool_echo:invoke(Input, _Ctx) -> {ok, Input}`. Test `echo_returns_input_test` asserts `{ok, #{message => <<"hello">>}}` equals the input.
- Criterion 3 — pass: `soma_tool_sleep:invoke/2` calls `timer:sleep(Ms)` then `{ok, Input}`. Test `sleep_waits_requested_ms_test` records monotonic time around the call, asserts gap >= 50ms and reply matches `{ok, _}`.
- Criterion 4 — pass: `soma_tool_fail:invoke(#{mode := error} = I, _)` returns `{error, maps:get(reason, I, failed)}`. Test `fail_error_mode_returns_error_test` asserts `{error, boom}`.
- Criterion 5 — pass: `soma_tool_fail:invoke(#{mode := crash} = I, _)` calls `error(Reason)`. Test `fail_crash_mode_raises_test` uses `?assertError(boom, ...)`, so no value returns.
- Criterion 6 — pass: `soma_tool_file_read:invoke(#{path := P}, #{root := R})` resolves under root then `file:read_file`. Test `file_read_returns_bytes_test` writes `note.txt` under a temp root, reads via `path => <<"note.txt">>`, asserts the bytes back.
- Criterion 7 — pass: Test `file_write_then_read_roundtrips_test` writes `roundtrip.txt` with `soma_tool_file_write:invoke/2`, reads same path with `soma_tool_file_read:invoke/2`, asserts `{ok, <<"bytes written then read back">>}`.
- Criterion 8 — pass: `soma_tool_file:resolve_under_root/2` uses `filelib:safe_relative_path` which returns `unsafe` on `..` escape. Test `file_dotdot_escape_rejected_test` asserts `{error, _}` for `<<"../escaped_write.txt">>` write and `<<"../escaped_read.txt">>` read, and `?assertNot(filelib:is_regular(Escaped))` confirms no file created at the escaped destination. Verified empirically: `safe_relative_path(<<"../escaped.txt">>, Root) -> unsafe`.
- Criterion 9 — pass: Test `file_absolute_outside_root_rejected_test` asserts `{error, _}` for an absolute path to a sibling dir, plus `?assertNot(filelib:is_regular(OutsideWrite))`. Verified empirically: `safe_relative_path(<<"/etc/passwd">>, Root) -> unsafe`. Also confirmed escaping symlinks are rejected and in-root symlinks pass.
- Criterion 10 — pass: `soma_tool_registry:lookup(R, Name)` returns `{ok, Module}` on a map hit. Test `registry_lookup_hit_test` registers `echo => soma_tool_echo`, asserts `{ok, soma_tool_echo}`.
- Criterion 11 — pass: `lookup/2` returns `{error, not_found}` on miss. Test `registry_lookup_miss_test` asserts `{error, not_found}` against an empty registry.
- Criterion 12 — pass: `soma_tool_registry:names/1` returns `maps:keys/1`. Test `registry_lists_names_test` registers echo/sleep/fail, asserts sorted names equal `[echo, fail, sleep]`.
- Criterion 13 — pass: Test `describe_has_required_keys_test` loops all five tool modules, asserts each `describe/0` map has keys `name, effect, idempotent, timeout_ms` and `effect` is in `[identity, reader, state]`. Source confirms: echo/sleep/fail effects identity/reader/identity, file_read reader, file_write state.
