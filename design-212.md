# [cc] Planning prompt consumes the tool catalog

## Current state

Planning mode's system prompt is built by `soma_actor:planning_system_prompt/1`
(`apps/soma_actor/src/soma_actor.erl`, ~line 909). With a concrete allowlist it
says "Answer with a Lisp plan of the form (run-steps ...) using only these
tools: echo, file_read." — names only. With an `all` policy it says only
"Answer with a Lisp plan of the form (run-steps ...)." and names nothing.

The model gets no descriptions and no param specs. So it guesses: wrong args
fail later at `soma_lfe:compile/2` or at the tool itself, and invented tool
names get rejected by the policy gate. T.1 (#203) already built the missing
half — `soma_tool_registry:catalog/0` returns `#{name, description, params}`
for every described tool, including config-registered tools from
`~/.soma/tools/` (#205), and it is proven to never leak runtime descriptor
fields (`docs/contracts/tool-catalog-test-contract.md`). Nothing consumes it
in the planning path yet.

The prompt is built inside `build_call_opts/2`'s `plan => true` branch, per
call. `planning_tools/2` already threads the actor's policy allowlist into the
`model_config` the builder reads. Both functions are pure today; the planning
eunit test (`soma_actor_call_opts_tests`) calls `build_call_opts/2` with no
registry process running.

## Approach

Fetch the catalog at the existing build site and keep the renderer pure:

- `build_call_opts/2`, in the `plan => true` branch only, calls
  `soma_tool_registry:catalog/0` and passes the result to a new
  `planning_system_prompt(AllowedTools, Catalog)`. Every prompt build reads
  the live registry, so a tool registered after actor start shows up in the
  next prompt with no restart (criterion 3). The non-planning path never
  touches the registry and stays byte-for-byte what it is.
- `planning_system_prompt/2` stays pure. With a concrete allowlist it keeps
  today's sentence — the `(run-steps ...)` directive plus the plain name list
  of *all* allowed tools — and appends one Lisp `(tool ...)` block per allowed
  tool that has a catalog entry, carrying its name, description, and params.
  An allowed tool without a catalog entry stays in the plain name list and
  gets no block. A catalog entry outside the allowlist is filtered out. With
  `all`, it keeps the bare directive sentence and appends a block for every
  catalog entry.
- The blocks are built from `catalog/0` entries only — never from raw
  descriptors — so the T.1 no-leak guarantee carries to this surface by
  construction: an entry simply has no `module` / `executable` / `argv` /
  `effect` / `idempotent` / `timeout_ms` to render.

Two rendering decisions worth pinning:

1. **Tool names keep their registry spelling** (`atom_to_binary/2`,
   underscores). `soma_lisp:render/1` maps `_` to `-` in symbols, so pushing a
   catalog entry through it would print `file-read` — and `soma_lfe`'s reader
   makes atoms verbatim, so a plan written with that spelling resolves to a
   different atom and fails registry lookup. Dev must render names directly
   and may use `soma_lisp:render/1` only for string values (description,
   param docs), where its quoting/escaping is exactly right.
2. **The block shape mirrors the `(tool ...)` config form** from
   `docs/tool-abstraction.md` §5 — for example
   `(tool (name file_read) (description "...") (params (param (name "path") (type string) (required true) (doc "..."))))`.
   The exact sub-form layout is Dev's call; the criteria pin content, not
   layout.

One knock-on change: the existing eunit test
`planning_mode_builds_run_steps_system_message_over_allowed_tools_test` calls
`build_call_opts/2` with `plan => true` and no registry running. After this
change that path does a `gen_server:call` to `soma_tool_registry`, so the test
gains the same `{setup, fun soma_tool_registry:start_link/0, ...}` fixture
`soma_tool_registry_tests` already uses. No fallback `catch` for a missing
registry: in any real deployment `soma_runtime` starts the registry before an
actor exists, and a planning prompt silently built without its catalog would
be a worse failure than a loud crash in a broken node.

Docs: add a planning-prompt section to
`docs/contracts/tool-catalog-test-contract.md` mapping these guarantees to
their tests, and flip the §8 T.1 note in `docs/tool-abstraction.md` ("planning
prompt consumption ... still open") to done.

Out of scope, per the issue: policy gate, normalization, budgets, token
budgeting, JSON-Schema rendering.

## Acceptance criteria → tests

Criteria 1–3 are naturally red today (the current prompt carries no
descriptions at all). Criterion 4 is a regression pin on behaviour that is
already green — write its no-leak test after the rendering exists (staged
red: temporarily leak a descriptor field to see it fail, then remove the
leak), and re-run the existing planning CT cases unmodified.

### Criterion 1 — allowlisted catalog entries render as Lisp tool blocks
- Call chain: `soma_actor:send/2` (llm envelope) → `maybe_start_llm_call` →
  `planning_tools/2` → `soma_actor:build_call_opts/2` →
  `soma_tool_registry:catalog/0` → `planning_system_prompt/2`
- Test entry: `soma_actor:build_call_opts/2` — the prompt text is fully
  determined at the builder; the actor→builder wiring above it is already
  pinned by the existing planning eunit test and the planning CT suite
- Code boundary: `apps/soma_actor/src/soma_actor.erl` (`build_call_opts/2`
  planning branch, `planning_system_prompt/2`) plus
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl`
- Responsibility owner: `soma_actor` owns planning-prompt construction;
  `soma_tool_registry:catalog/0` owns catalog content
- Test: `test_planning_prompt_renders_allowed_catalog_entries` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl` — registry fixture;
  register one described tool and one description-less tool, allowlist those
  two plus `echo`, leave `file_write` off the allowlist; assert the prompt
  carries `(tool` blocks with name/description/params for the described
  allowed tools, no trace of `file_write`, the description-less tool's name
  in the plain list, and `(run-steps`

### Criterion 2 — `all` policy renders the whole catalog
- Call chain: same as criterion 1, with `allowed_tools => all` threaded from
  the policy by `planning_tools/2`
- Test entry: `soma_actor:build_call_opts/2` (same reason as criterion 1)
- Code boundary: same as criterion 1
- Responsibility owner: same as criterion 1
- Test: `test_planning_prompt_all_policy_renders_full_catalog` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl` — registry fixture;
  `plan => true` with `allowed_tools => all`; assert every `catalog/0` entry's
  name and description appear (the five seeded built-ins) plus `(run-steps`

### Criterion 3 — a tool registered at runtime appears in the next prompt
- Call chain: `soma_tool_registry:register_tool/1` → registry state; then
  `soma_actor:build_call_opts/2` → `soma_tool_registry:catalog/0` →
  `planning_system_prompt/2`
- Test entry: `soma_actor:build_call_opts/2` after a real
  `register_tool/1` call (no layer bypassed on either side)
- Code boundary: same as criterion 1 — the fresh `catalog/0` read per build
  is the behaviour under test; no registry change
- Responsibility owner: `soma_actor`'s build site owns reading fresh;
  `soma_tool_registry` owns serving the current catalog
- Test: `test_registered_tool_appears_in_next_planning_prompt` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl` — build a planning
  prompt, assert the new tool absent; `register_tool/1` a described manifest;
  build again with the same config; assert the tool's name and description
  present

### Criterion 4 — no runtime descriptor fields leak; planning gate contract holds
- Call chain (no-leak half): same as criterion 1, with a registered `cli`
  tool carrying distinctive `executable` / `argv` values and a description
- Test entry: `soma_actor:build_call_opts/2` (same reason as criterion 1)
- Code boundary: same as criterion 1 — rendering must consume `catalog/0`
  entries, never `resolve_descriptor/1`
- Responsibility owner: `soma_tool_registry:catalog/0` owns the no-leak
  guarantee at the source; `soma_actor` owns not reaching past it
- Test: `test_planning_prompt_carries_no_runtime_descriptor_fields` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl` — assert the prompt
  contains none of the registered tool's `executable` path, `argv` values,
  a built-in's module name, nor `effect` / `idempotent` / `timeout_ms` field
  text (staged red as described above)
- Gate-contract half (regression pin, tests unmodified): the existing CT
  cases `planning_mode_real_response_runs_plan_to_completion`,
  `planning_mode_malformed_plan_fails_task_actor_alive`,
  `planning_mode_off_yields_reply_proposal_unchanged`, and
  `planning_mode_api_key_appears_in_no_emitted_event` in
  `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl` stay green —
  fixed `response` seam, no model socket, content →
  `(run-steps ...)` → `soma_lfe:compile/2` → normalize → policy → budget

## Risks & trade-offs

- **`build_call_opts/2` is no longer pure in planning mode.** It gains one
  `gen_server:call` to the registry per prompt build. That is what the
  fresh-read criterion demands, and the cost is one local call against a
  small map. The non-planning path stays pure and untouched.
- **No fallback when the registry is down.** A planning build then crashes
  the LLM-call setup. Accepted: the registry starts under `soma_sup` before
  any actor can exist, and a silent catalog-less prompt would hide a broken
  node. The existing planning eunit test must gain the registry fixture.
- **The name-spelling trap is real.** Reusing `soma_lisp:render/1` for whole
  entries would print `file-read`, and a model that copies it writes plans
  that fail resolution. The renderer keeps registry spelling for names; the
  no-leak and criterion-1 tests both match on exact names, which pins this.
- **Prompt size grows with the catalog.** Unbounded in principle;
  deliberately not budgeted here (single-user, bounded tool counts, per the
  issue's out-of-scope list).
- **The prompt stays advisory.** A described tool in the prompt is not
  permission — the policy gate still judges the proposal, and an allowed but
  undescribed tool is still callable. This slice moves no authorization.
