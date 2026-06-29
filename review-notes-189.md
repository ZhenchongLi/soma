### Claude

## Verdict

Changes requested. The `(task ...)` compiler surface and its tests are fine on
the branch tip, and the full local gate passes. But the branch is stale against
`origin/main` and is not mergeable without manual doc conflict resolution. That
is not a nit; it is the thing that stops this branch from landing.

## Real issues

1. The branch does not merge cleanly with current `origin/main`.

   `git status --short --branch` reports the branch is `ahead 57, behind 3`.
   More importantly, `git merge-tree $(git merge-base HEAD origin/main) HEAD
   origin/main` reports both-side conflicts in `README.md`, `docs/cli.md`,
   `docs/design.md`, `docs/lfe-dsl.md`, and `docs/usage.md`. The current trunk
   has a docs refresh and public quick-start rewrite, while this branch rewrites
   the same sections for `(task ...)`. A merge/rebase will produce conflict
   markers unless those manuals are reconciled. Fix the conflicts against
   `origin/main` and preserve both the trunk status refresh and the new bounded
   Soma Lisp task surface.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] A single `(task ...)` top-level form compiles through `soma_lfe:compile/2` to `#{run => #{steps => Steps}}`.
  Artifact: `apps/soma_lfe/src/soma_lfe.erl:29` dispatches `task` to `parse_task/1`; `apps/soma_lfe/src/soma_lfe_parser.erl:78` returns `#{run => #{steps => Steps}}`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:5` proves the exact shape.

- [x] Each `let*` binding becomes one runtime step in binding order.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:99` reverses the accumulated parsed bindings once; `apps/soma_lfe/test/soma_lfe_task_tests.erl:23` asserts `[first, second, third]`.

- [x] A binding name becomes the runtime step `id`.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:190` writes `id => Id`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:40` asserts the compiled step id.

- [x] A `(tool ToolName ...)` call becomes the runtime step `tool`.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:117` accepts atom tool names and line `190` writes `tool => Tool`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:53` asserts `file_read`.

- [x] Literal `(Key Value)` task arguments use the existing coercions for strings, atoms, integers.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:250` routes task args through `parse_args/2`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:66` asserts binary string, atom, and integer outputs.

- [x] `(from Name)` as the only tool argument lowers to `#{from_step => Name}`.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:243` lowers bare `from`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:84` asserts `#{from_step => read}`.

- [x] `(Key (from Name))` lowers to `Key => {from_step, Name}`.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:264` rewrites field `from` to the existing `from_step` value shape; `apps/soma_lfe/test/soma_lfe_task_tests.erl:99` asserts `#{bytes => {from_step, read}}`.

- [x] `(timeout-ms N)` lowers to `timeout_ms => N` on the step map.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:207` extracts positive `timeout-ms`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:114` asserts `timeout_ms => 250`.

- [x] `(return Name)` validates that `Name` has already been bound.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:292` validates the return id against parsed step ids; the positive compile tests use bound returns, including `apps/soma_lfe/test/soma_lfe_task_tests.erl:5`.

- [x] Duplicate binding names fail with a `duplicate_binding` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:274` detects duplicate ids and emits `duplicate_binding`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:128` asserts the diagnostic.

- [x] Unknown `(from Name)` references fail with an `invalid_from_binding` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:289` remaps invalid from-step diagnostics to `invalid_from_binding`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:158` asserts unknown `missing`.

- [x] Forward `(from Name)` references fail with an `invalid_from_binding` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:289` uses the ordered existing from-step validator; `apps/soma_lfe/test/soma_lfe_task_tests.erl:143` asserts forward `later`.

- [x] Missing `(return Name)` bodies fail with an `invalid_return` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:90` emits `invalid_return` for a `let*` without a return body; `apps/soma_lfe/test/soma_lfe_task_tests.erl:171` asserts it.

- [x] Unknown `(return Name)` references fail with an `invalid_return` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:292` emits `invalid_return` for unbound returns; `apps/soma_lfe/test/soma_lfe_task_tests.erl:183` asserts `missing`.

- [x] Invalid `(timeout-ms N)` values fail with an `invalid_timeout` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:220` and `apps/soma_lfe/src/soma_lfe_parser.erl:227` emit `invalid_timeout`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:196` asserts `timeout-ms 0`.

- [x] Malformed `(task ...)` roots fail with an `invalid_task_form` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:94` emits `invalid_task_form`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:210` asserts `(task)`.

- [x] Malformed `let*` bodies fail with an `invalid_let_star` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:85` emits `invalid_let_star` for extra body forms; `apps/soma_lfe/test/soma_lfe_task_tests.erl:218` asserts it.

- [x] Malformed bindings fail with an `invalid_binding` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:123` and `apps/soma_lfe/src/soma_lfe_parser.erl:132` emit `invalid_binding`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:232` asserts malformed binding input.

- [x] Malformed `(tool ...)` calls fail with an `invalid_tool_form` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:198` constructs `invalid_tool_form`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:245` asserts a non-atom tool name.

- [x] Reserved task words fail as binding names with a `reserved_form` diagnostic.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:137` lists reserved words and `apps/soma_lfe/src/soma_lfe_parser.erl:141` emits `reserved_form`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:258` asserts `return` as a binding name.

- [x] Unsupported task control heads fail with a `reserved_form` diagnostic: `if`, `cond`, `loop`, `recur`.
  Artifact: `apps/soma_lfe/src/soma_lfe_parser.erl:147` scans for unsupported control forms and `apps/soma_lfe/src/soma_lfe_parser.erl:179` emits `reserved_form`; `apps/soma_lfe/test/soma_lfe_task_tests.erl:271` asserts all four heads.

- [x] README quick start uses `(task ...)` as the primary `soma run` example.
  Artifact: `README.md:95` introduces the static task CLI example and `README.md:99` starts the example with `(task`; `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:39` asserts it.

- [x] `docs/lfe-dsl.md` documents `(task ...)` as the public static task form.
  Artifact: `docs/lfe-dsl.md:37` is the public static task section and `docs/lfe-dsl.md:39` documents `(task ...)`; `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:49` asserts it.

- [x] `docs/lfe-dsl.md` documents `(run ...)` as the compatibility/core run form.
  Artifact: `docs/lfe-dsl.md:43` documents `(run ...)` as the compatibility/core run form; `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:57` asserts it.

- [x] `docs/lfe-dsl.md` includes the sentence: `When a need is dynamic, keep the dynamic decision in the actor/planner layer and submit a new bounded static Soma Lisp task for each execution attempt.`
  Artifact: exact sentence is present at `docs/lfe-dsl.md:47`; `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:65` asserts it.

- [x] `docs/design.md` states `Soma Lisp source -> soma_lfe:compile/2 -> validated maps -> OTP execution`.
  Artifact: exact boundary statement is present at `docs/design.md:100`; `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:75` asserts it.

- [x] `docs/cli.md` describes `soma run FILE` as reading Soma Lisp source.
  Artifact: `docs/cli.md:105` says `soma run FILE reads Soma Lisp source`; `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:95` asserts it.

- [x] `docs/usage.md` describes `soma run FILE` as reading Soma Lisp source.
  Artifact: `docs/usage.md:903` says `soma run FILE reads Soma Lisp source`; `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:85` asserts it.

Verification:

- `rebar3 eunit --module=soma_lfe_task_tests` passed: 20 tests, 0 failures.
- `rebar3 eunit --module=soma_lfe_task_doc_tests` passed: 7 tests, 0 failures.
- `rebar3 eunit && rebar3 ct` passed: 286 EUnit tests and 350 Common Test tests.
