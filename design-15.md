# [cc] v0.2: add manifest validation and normalization

## Current state

A tool's metadata is whatever its `describe/0` returns. For `echo` that is
`#{name => echo, effect => identity, idempotent => true, timeout_ms => 1000}`
(`apps/soma_tools/src/soma_tool_echo.erl`). The `soma_tool` behaviour
(`apps/soma_tools/src/soma_tool.erl`) types this as a bare `spec() :: map()`
with no required keys and no checking. `soma_tool_registry`
(`apps/soma_tools/src/soma_tool_registry.erl`) only ever holds a
`name => module` map; it never looks at the metadata at all.

So nothing validates a tool's metadata before it reaches the runtime. v0.2 adds
an `adapter` field — `erlang_module` for the in-BEAM tools we have today, `cli`
for external executables. With a new adapter field and an adapter-specific
schema, a malformed tool definition (wrong `effect`, a `cli` entry that folds a
whole shell line into `executable`, a missing module reference) would sit
unnoticed until a run tried to use it. There is no module whose job is to say
"this manifest is well-formed" up front.

## Approach

Add one new module, `soma_tool_manifest`, with a single public entry point:

```
soma_tool_manifest:normalize(map()) -> {ok, map()} | {error, Reason}
```

`normalize/1` does both jobs the issue asks for. On a well-formed manifest it
returns `{ok, Manifest}` carrying the manifest in one canonical shape. On a
malformed one it returns `{error, Reason}` where `Reason` names the offending
field. There is no separate `validate/1`; validation is the part of normalize
that can fail, and folding them together is what makes the idempotence criterion
(`normalize(normalize(M)) == normalize(M)`) meaningful.

The canonical field names come from `docs/tool-manifest.md`:

- Shared keys: `name`, `effect`, `idempotent`, `timeout_ms`, `adapter`.
- `erlang_module` adapter: a `module` key holding the implementing module atom
  (the doc's valid example uses `module => soma_tool_file_read`).
- `cli` adapter: `executable` (a single program path or name) plus `argv` (a
  list of argument strings).

Checks, in order, with the field each one blames:

1. Each shared key is present. Missing → `{error, {missing_field, Key}}`.
2. `effect` is one of `identity | reader | state`. Otherwise
   `{error, {invalid_effect, Value}}`.
3. `idempotent` is a boolean. Otherwise `{error, {invalid_idempotent, Value}}`.
4. `timeout_ms` is a positive integer. Otherwise
   `{error, {invalid_timeout_ms, Value}}`.
5. `adapter` is `erlang_module` or `cli`. Otherwise
   `{error, {invalid_adapter, Value}}`.
6. For `erlang_module`: `module` is present and is an atom. Otherwise
   `{error, {missing_field, module}}`.
7. For `cli`: `executable` is a single token, and `argv` is a list. A
   non-list `argv` → `{error, {invalid_argv, Value}}`; a multi-token
   `executable` → `{error, {invalid_executable, Value}}`.

Every error reason is a `{Tag, ...}` tuple whose tag carries the field name, so
the "names the offending field" criterion is satisfied by the same tuples the
other rejection criteria assert on.

**The shell-string detection rule.** A `cli` `executable` is rejected when it
carries internal whitespace. `"echo"` and `"/bin/echo"` pass; `"echo hi"` and
`"/bin/sh -c 'grep ...'"` fail. This is the rule the issue's open question lands
on: a single program path or name passes, a value that bundles the program with
arguments fails. Whitespace is the signal that arguments were smuggled into the
field instead of going through `argv`. The check accepts both Erlang strings
(lists) and binaries for `executable`, since either is a plausible authoring
form, and looks for any space or tab.

**Canonical shape and idempotence.** Normalize returns the manifest as a map
holding exactly the keys for its adapter: the five shared keys plus `module`
for `erlang_module`, or plus `executable` and `argv` for `cli`. Any key not in
that set is dropped, so two manifests that differ only by stray keys normalize
to the same map. Because the output already holds only canonical keys in
canonical form, feeding it back through `normalize/1` produces an equal map.
That is what the idempotence test asserts, rather than comparing against a
hard-coded golden map.

This issue stays inside the validation layer. It does not touch
`soma_tool_registry`, does not migrate the existing tools' `describe/0`, and
does not run or define any CLI input/output protocol. The `module` and tests
live under `apps/soma_tools`, alongside the other tool code.

## Acceptance criteria → tests

All tests are EUnit tests in
`apps/soma_tools/test/soma_tool_manifest_tests.erl`, calling
`soma_tool_manifest:normalize/1` directly. There is no caller chain above this
module — a manifest is a plain map handed straight to the validator — so every
criterion uses the same entry.

### Criterion 1 — well-formed erlang_module manifest is accepted
- Call chain: none (direct module call — manifest is a plain map argument)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_accepts_erlang_module` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 2 — well-formed cli manifest is accepted
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_accepts_cli` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 3 — missing a required shared field is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_missing_shared_field` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl` (one case per field:
  `name`, `effect`, `idempotent`, `timeout_ms`, `adapter`)

### Criterion 4 — bad effect value is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_bad_effect` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 5 — non-boolean idempotent is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_non_boolean_idempotent` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 6 — non-positive-integer timeout_ms is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_bad_timeout_ms` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl` (covers zero, a negative,
  and a non-integer)

### Criterion 7 — unknown adapter type is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_unknown_adapter` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 8 — erlang_module missing its module reference is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_erlang_module_without_module` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 9 — cli executable that is a shell command string is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_shell_string_executable` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl` (a single token passes,
  an `executable` carrying whitespace-separated arguments fails)

### Criterion 10 — cli argv that is not a list is rejected
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_rejects_non_list_argv` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl`

### Criterion 11 — rejection reason names the offending field
- Call chain: none (direct module call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_reject_reason_names_field` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl` (asserts each error
  reason tuple carries the field it blames)

### Criterion 12 — re-normalizing a normalized manifest returns an equal map
- Call chain: none (direct module call, output fed back into the same call)
- Test entry: `soma_tool_manifest:normalize/1`
- Test: `test_normalize_is_idempotent` in
  `apps/soma_tools/test/soma_tool_manifest_tests.erl` (asserts
  `normalize(M2) == {ok, M2}` where `{ok, M2} = normalize(M)`, for both
  adapters)

## Risks & trade-offs

- The shell-string rule is "any internal whitespace fails". A program path that
  legitimately contains a space (for example a macOS app path) would be
  rejected. For v0.1's built-in tools and v0.2's first CLI tools this never
  comes up, and the whole point of the field is that it holds one program, not a
  command line. If a real spaced path shows up later, the rule can move to a
  more precise form. Whitespace is the cheap signal that catches the case the
  contract cares about — arguments smuggled into `executable`.
- Dropping unknown keys during normalization means a typo'd key (say
  `idempotnet`) is silently discarded rather than flagged. The required-field
  check still fires, so the real `idempotent` being absent is caught — the typo
  just does not get its own error. Keeping normalize strict about required keys
  but lenient about extras keeps the idempotence property simple, which the
  canonical-shape criterion depends on.
- `normalize/1` is the only public function. If a later issue wants validation
  without the canonical reshaping, it has to split them then. For this issue the
  two are the same operation, and one entry point is fewer moving parts to test.
