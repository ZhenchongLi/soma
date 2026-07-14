# [cc] runtime service RS.1a: (invoke ...) envelope form and pure normalization

## Current state

`soma_lfe:compile/2` is already the compile-only Lisp edge. It reads one source
form with `soma_lfe_reader`, dispatches on the top-level head, and returns Erlang
data. It has no runtime dependency. The `soma_lfe` application already lists
only `kernel` and `stdlib`.

The compiler has no `(invoke ...)` dispatch today. Such a form falls through to
`soma_lfe_parser:parse_run/1` and is rejected as an invalid run form.
`soma_lfe_parser` does have the step production this issue needs.
`parse_proposal_steps/1` builds source-ordered canonical steps for
`(run-steps ...)`, `(explore ...)`, and message step lists. It handles empty
arguments, both `from_step` shapes, and optional positive `timeout_ms` values.

The existing field parsers usually accumulate into a map. A repeated field can
therefore replace its earlier value. That behavior is not safe for an invoke
envelope because the compiled map cannot show that a duplicate existed.

There is no `soma_service_envelope` module. `soma_proposal:normalize/1` is a
useful model for a pure actor-layer normalizer, but its proposal kinds and step
checks are not the service-envelope contract. Reusing it would also return the
wrong error codes for this issue.

`soma_lisp:render/1` has special forms for explore data, events, results, and
message envelopes. An invoke map currently reaches the generic map renderer.
The result has no `invoke` head and cannot compile back to the same map. The
`soma_event_store` application that owns this renderer already lists only
`kernel` and `stdlib`.

No service owner or ingress path exists yet. That is expected. RS.1a ends after
compile, normalization, and rendering. It must not start a service process,
open a socket, append an event, or execute a step.

## Approach

Add an `invoke` clause to `soma_lfe:dispatch/1` and export
`soma_lfe_parser:parse_invoke/1` as the production parser entry. The accepted
top-level grammar is the locked issue grammar:

```lisp
(invoke
  (api-version "1")
  (request-id "request-1")
  (tool (name echo) (args (value "hello")))
  (scope "echo")
  (deadline-ms 2000)
  (max-output-bytes 4096)
  (correlation-id "correlation-1")
  (artifacts "artifact-1"))
```

The operation position may instead contain one form like this:

```lisp
(steps
  (step (id read) (tool file_read) (args (path "input.txt")))
  (step (id echo) (tool echo) (args (from_step read))))
```

Parse invoke fields with an explicit seen-field set. Reject a repeated
top-level field before updating the accumulator. Apply the same rule to the
`name` and `args` children of a tool operation. A second operation with the same
head is a duplicate field. A tool and a steps form in one envelope is an
invalid operation. Unknown top-level fields are rejected rather than dropped.

Keep type and policy validation out of the compiler where the raw form can be
represented safely. For example, an integer `api-version` should compile into
the candidate map and then fail in `soma_service_envelope:normalize/1`. The
compiler still owns structural failures that cannot be represented in a map.
Those failures use one fixed diagnostic and never format the rejected value.

Build a tool operation only after all fields have been read. This lets a
`request-id` appear before or after the tool form. When it is present, copy it
to the canonical step id. The compiler result for a valid tool operation is:

```erlang
#{kind => invoke,
  api_version => <<"1">>,
  request_id => <<"request-1">>,
  operation =>
      #{kind => tool,
        step =>
            #{id => <<"request-1">>,
              tool => echo,
              args => #{value => <<"hello">>}}}}
```

Parse a `(steps ...)` operation by calling the existing
`parse_proposal_steps/1` directly. Do not add another step parser. Collapse any
malformed operation detail to the fixed `invalid_operation` diagnostic so a
large rejected child cannot enter an error message.

Add `apps/soma_actor/src/soma_service_envelope.erl` with only `normalize/1`
exported. It is a total pure function. It accepts arbitrary terms and returns
either `{ok, CanonicalEnvelope}` or one fixed one-element diagnostic list. The
diagnostic map carries a typed `code`, a fixed binary `message`, and no rejected
term. Compiler-owned errors keep the same bounded diagnostic shape and add the
usual `line => 0` source position.

Validate in a stable order so a malformed map always has one predictable
result. Check the required API version first. Only binary `<<"1">>` is
supported. Check the required request id next and require a binary. Then reject
keys outside this allowlist:

```erlang
[kind, api_version, request_id, operation, scope, deadline_ms,
 max_output_bytes, correlation_id, artifacts]
```

The normalizer rebuilds the output from that allowlist. It sets `kind` to
`invoke`. Optional keys are copied only when present. It does not silently drop
an unknown key. Re-normalizing a canonical envelope must return the same map.
A non-map candidate or a candidate with a non-`invoke` kind follows the fixed
`invalid_operation` path rather than raising.

A tool operation is valid only when it has one step with exactly `id`, `tool`,
and `args`. The id must equal the request id. The tool remains the atom produced
by the current Lisp symbol grammar. Arguments remain the existing canonical
step map and are not inspected for service policy. The normalizer reconstructs
the three-key step so stray nested fields cannot pass through.

Credential, shell-command, and raw-payload fields are not top-level envelope
fields. The compiler and normalizer reject them as unknown fields. Do not scan
inside tool arguments for those names because tool arguments keep the existing
canonical step contract.

A steps operation is valid only when it contains a proper list of canonical
step maps. Each step has atom `id` and `tool` values, a map under `args`, and at
most one positive integer `timeout_ms`. Preserve the list and each accepted
step value without reordering. Keep the existing production's empty-list
behavior rather than adding a different rule for `(steps)`.

Validate each optional budget as a positive integer. Validate scope as a proper
list of binaries and cap each entry at 255 bytes. A malformed or oversized
scope entry follows the fixed `scope_entry_too_large` path without carrying the
entry. Scope remains data only. RS.1b owns comparison with the requested tools.

Validate artifacts as a proper list of binaries. Treat them as opaque
references. Do not resolve or store them. Validate `correlation_id` as a binary.
The issue sets no additional size cap for request ids, correlation ids, or
artifact references, so this slice should not invent one.

Use these exact error codes across the compiler and normalizer boundaries:

```text
missing_api_version
unsupported_api_version
missing_request_id
invalid_request_id
duplicate_field
unknown_field
invalid_operation
invalid_budget
scope_entry_too_large
invalid_artifacts
invalid_correlation_id
```

Give every code one fixed diagnostic term. Do not include an unknown key, a
duplicate field name, a bad value, an operation child, or a scope entry in the
term. The invalid-case test should compare each small rejection with a 64 KiB
counterpart using full term equality. It should also assert that all eleven
codes are distinct.

Add a leading `soma_lisp:render/1` clause for canonical invoke maps. Render
fields in one canonical order: API version, request id, operation, scope,
deadline, output budget, correlation id, then artifacts. Render internal
underscore keys with the locked hyphenated wire names.

For a tool operation, render the tool and args but not the step id. The top-level
request id recreates that id during compilation. For a steps operation, render
each map as a `(step ...)` form in list order. Refactor the current explore step
renderer into neutral canonical-step and canonical-args helpers. Invoke and
explore rendering can then share correct handling for empty args,
`from_step`, atom values, and `timeout_ms`. Keep message-envelope rendering on
its current path.

Do not add an actor call, runtime call, registry lookup, event append, or socket
operation to any of these functions. Do not change `soma_actor.erl`,
`soma_run`, the CLI wire, or either application dependency list. The source
guard should scan `soma_lfe.erl`, `soma_lfe_parser.erl`,
`soma_service_envelope.erl`, and `soma_lisp.erl` for atom-creation BIFs. It
should not scan `soma_lfe_reader.erl` because reader-wide atom hygiene is issue
#235.

Create `docs/contracts/RS.1a-test-contract.md` after the production tests are
green. Give each issue criterion one section and name the exact proving module
and function. Add a source-file EUnit guard for that map. No other product or
runtime documentation is part of this slice.

## Acceptance criteria → tests

### Criterion 1 — a tool envelope compiles and normalizes to the exact allowlisted map

- Call chain: RS.1a caller → `soma_lfe:compile/2` →
  `soma_lfe_reader:read_forms/1` → `soma_lfe:dispatch/1` →
  `soma_lfe_parser:parse_invoke/1` →
  `soma_service_envelope:normalize/1`.
- Test entry: `soma_lfe:compile/2`, followed by the production normalizer. No
  layer in the RS.1a path is bypassed.
- Code boundary: invoke dispatch and parsing in
  `apps/soma_lfe/src/soma_lfe.erl` and
  `apps/soma_lfe/src/soma_lfe_parser.erl`, plus canonical validation in
  `apps/soma_actor/src/soma_service_envelope.erl`.
- Responsibility owner: `soma_lfe` owns the locked wire grammar and duplicate
  preservation. `soma_service_envelope` owns the accepted canonical map.
- Test: `test_valid_tool_invoke_compiles_and_normalizes` in
  `apps/soma_actor/test/soma_service_envelope_tests.erl`.

### Criterion 2 — a steps envelope reuses the run-steps production and preserves order

- Call chain: `soma_lfe:compile/2` → invoke dispatch →
  `soma_lfe_parser:parse_invoke/1` → `parse_proposal_steps/1` →
  `soma_service_envelope:normalize/1`. The comparison source enters
  `soma_lfe:compile/2` → `parse_proposal/1` → the same
  `parse_proposal_steps/1` function.
- Test entry: `soma_lfe:compile/2` for an invoke source and a matching
  `(run-steps ...)` source. The invoke candidate then enters the production
  normalizer. The case compares `term_to_binary/1` output for both step lists.
  It also reads the production parser source to pin that both branches call the
  same private `parse_proposal_steps/1` helper. No test-only parser export is
  added.
- Code boundary: the invoke operation clause around the existing
  `parse_proposal_steps/1` function in
  `apps/soma_lfe/src/soma_lfe_parser.erl`, and steps validation in
  `apps/soma_actor/src/soma_service_envelope.erl`.
- Responsibility owner: `soma_lfe_parser` owns the single source-to-step
  production. `soma_service_envelope` preserves accepted canonical steps.
- Test: `test_valid_steps_invoke_matches_run_steps_production` in
  `apps/soma_actor/test/soma_service_envelope_tests.erl`.

### Criterion 3 — every invalid class has a distinct fixed bounded error

- Call chain: malformed Lisp → `soma_lfe:compile/2` → fixed compiler
  diagnostic, or compiled and programmatic candidate map →
  `soma_service_envelope:normalize/1` → fixed normalization diagnostic.
- Test entry: the production compiler for duplicate and malformed source
  cases. Direct `soma_service_envelope:normalize/1` entry is also required to
  prove that programmatic callers cannot bypass validation with a raw map.
- Code boundary: invoke field accumulation and fixed structural diagnostics in
  `apps/soma_lfe/src/soma_lfe_parser.erl`, plus all allowlist and value checks
  in `apps/soma_actor/src/soma_service_envelope.erl`.
- Responsibility owner: `soma_lfe_parser` owns duplicate detection before map
  construction. `soma_service_envelope` owns typed validation for every
  representable candidate.
- Test: `test_invalid_invoke_classes_return_fixed_typed_errors` in
  `apps/soma_actor/test/soma_service_envelope_tests.erl`.

### Criterion 4 — every canonical invoke shape survives render and compile

- Call chain: canonical invoke map → `soma_lisp:render/1` → invoke renderer →
  `soma_lfe:compile/2` → `soma_lfe_parser:parse_invoke/1`.
- Test entry: `soma_lisp:render/1` with a table containing tool and steps
  envelopes. The table covers present and absent optional fields, empty args,
  both `from_step` shapes, a step timeout, ordered scope, and ordered artifact
  references.
- Code boundary: invoke classification and canonical field, operation, step,
  and argument rendering in `apps/soma_event_store/src/soma_lisp.erl`.
- Responsibility owner: `soma_lisp` owns the reversible canonical term-to-Lisp
  form. `soma_lfe` remains the inverse parser.
- Test: `test_canonical_invoke_maps_round_trip_through_render_and_compile` in
  `apps/soma_event_store/test/soma_lisp_invoke_tests.erl`.

### Criterion 5 — compile and normalization remain pure boundaries

- Call chain: `soma_lfe:compile/2` → invoke parser →
  `soma_service_envelope:normalize/1`. Dependency and atom checks use none
  (direct source-file read).
- Test entry: preload the production modules, start one standalone event store,
  record `erlang:processes/0` and `soma_event_store:all/1`, then compile and
  normalize one valid invoke. Compare the process set and events afterward.
  Trace the test process for transient spawns during the measured call too.
  The same case consults both application manifests and asserts exact
  `[kernel, stdlib]` dependency lists. It scans the four named production
  sources for all four atom-creation BIF names.
- Code boundary: the four production source files touched by this slice and
  `apps/soma_lfe/src/soma_lfe.app.src` plus
  `apps/soma_event_store/src/soma_event_store.app.src`.
- Responsibility owner: the compiler and renderer applications own their
  `[kernel, stdlib]` dependency boundaries. The compiler, normalizer, and
  renderer modules own process-free and atom-creation-free behavior.
- Test: `test_invoke_compile_normalize_boundary_is_pure` in
  `apps/soma_actor/test/soma_service_envelope_tests.erl`.

### Criterion 6 — the RS.1a contract names every proving test

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/contracts/RS.1a-test-contract.md` and checks one
  criterion heading and one full module-function name for each of the six issue
  criteria.
- Code boundary: `docs/contracts/RS.1a-test-contract.md` and
  `apps/soma_actor/test/soma_rs1a_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the durable guarantee-to-proof
  map for RS.1a.
- Test: `test_rs1a_contract_maps_every_criterion_to_proving_case` in
  `apps/soma_actor/test/soma_rs1a_contract_doc_tests.erl`.

## Risks & trade-offs

- Fixed diagnostics do not tell a caller which unknown or repeated field was
  rejected. That loss of detail is deliberate. It prevents attacker-sized
  values and external names from entering errors. The typed code remains enough
  for callers to classify the failure.
- The parser and the normalizer both understand canonical step shape. The
  parser must produce it from Lisp. The normalizer must defend raw Erlang-map
  callers. Keeping `parse_proposal_steps/1` shared and comparing its output in
  the steps test limits drift, but the two boundaries still need separate
  validation code.
- Canonical maps do not retain original Lisp field order. Rendering chooses one
  stable order. The data round trip is exact even though the rendered bytes can
  differ from the original source.
- The issue caps only scope entries. A valid request id, correlation id, or
  artifact reference can still be large. Adding limits here would create an
  unapproved wire rule. The later ingress slice must bound its frame before
  calling this pure boundary.
- `soma_lfe_reader` still creates atoms for Lisp symbols. This slice adds no
  atom-creation BIF to the invoke compiler, normalizer, or renderer, but it does
  not solve the reader-wide problem tracked by #235.
- An exact global process-set assertion can see unrelated test-runner churn.
  Preloading modules and measuring in one short, isolated EUnit case reduces
  that risk. The spawn trace is the stronger proof that the call path itself
  created no transient child.
