## Current state

`soma_lfe:compile/2` already dispatches a top-level `(task ...)` form to
`soma_lfe_parser:parse_task/1`. The parser lowers the bounded public task form to
the same canonical `#{run => #{steps => Steps}}` map used by the older `(run ...)`
path, and `apps/soma_lfe/test/soma_lfe_task_tests.erl` already covers the compile
contract: binding order, binding-to-step ids, tool names, literal arg coercions,
bare and field-level `(from ...)`, `(timeout-ms ...)`, duplicate/unknown/forward
references, malformed task shapes, reserved names, and rejected control heads.

The source docs are partially aligned. `README.md`, `docs/cli.md`, `docs/usage.md`,
and `docs/lfe-dsl.md` already mention `(task ...)` in some user-facing sections.
However, stale reference and mirror content still presents `(run ...)` as the
primary workflow/request form:

- `site/src/content/docs/start/quick-start.md` uses a `(run ...)` workflow example.
- `docs/cli.md` still starts its "Lisp Request Forms" reference with `(run ...)`.
- `docs/usage.md` and `site/src/content/docs/guides/usage.md` summarize run wire
  requests as `(run ...)`.
- `site/src/content/docs/guides/lfe-dsl.md` is an older mirror centered on v0.3
  `(run ...)`.
- `site/src/content/docs/guides/cli.md` describes `soma run WORKFLOW` as a
  `(run ...)` s-expression.
- `docs/roadmap.md`, `site/src/content/docs/reference/roadmap.md`, `AGENTS.md`,
  and `docs/lisp-messages.md` only describe the older L.1-L.5 Lisp track, not
  bounded Soma Lisp v1 with the public task surface.
- No `docs/contracts/` task-form contract exists yet, and the README contract-doc
  index does not link one.

The existing documentation proof style is substring-based EUnit tests that read
Markdown files directly, plus site shell scripts that build the site and assert
tokens in rendered HTML. That style is sufficient for this docs-only issue, with
one stronger check: the site quick-start example should be extracted and compiled
through `soma_lfe:compile/2` so the public example is not only textual.

`agents/architect.md` is absent from this worktree, so this design follows the
schema supplied in the relay request. No runtime, compiler, CLI protocol, planner,
provider, policy, or resume behavior changes are in scope.

## Approach

Keep this as a documentation and documentation-test alignment slice.

1. Make `(task ...)` the public static task form wherever users first encounter
   run workflows:
   - Change the site quick-start workflow to the same bounded task shape used in
     `README.md`.
   - In `docs/cli.md`, make `(task ...)` the first run request form in the
     request-form reference, then show `(run ...)` as the compatibility/core run
     form.
   - In `docs/usage.md` and the site usage mirror, describe local run requests as
     public `(task ...)` source, with `(run ...)` preserved as compatibility/core
     syntax and as the detach marker carrier where relevant.
   - In `site/src/content/docs/guides/lfe-dsl.md`, mirror the source
     `docs/lfe-dsl.md` shape: "Public static task form" first, then
     "Compatibility/Core Run Form".
   - In `site/src/content/docs/guides/cli.md`, change `soma run WORKFLOW` input
     language from "a `(run ...)` s-expr" to "Soma Lisp source", naming `(task ...)`
     as the public static task form and `(run ...)` as compatibility/core.

2. Record built state consistently:
   - Update `docs/roadmap.md` and `site/src/content/docs/reference/roadmap.md` to
     say bounded Soma Lisp v1 with the public task surface is built. Keep L.1-L.5
     as the older Lisp-edge subtrack, not the full current public task surface.
   - Update `AGENTS.md` current Lisp state to name bounded Soma Lisp v1 public task
     surface.
   - Update `docs/lisp-messages.md` so the implemented grammar table includes
     `(task ...) -> #{run => #{steps => [...]}}`, and add a built slice for bounded
     Soma Lisp v1 / public task surface.
   - Update `docs/zh/what-is-soma.zh.md` so the contract-doc reading list points
     readers to the new task-form contract.

3. Add a new contract doc:
   - Create `docs/contracts/task-form-test-contract.md`.
   - The contract should explicitly scope itself to the bounded Soma Lisp v1 public
     task surface, not to a new runtime layer.
   - Map compile behavior to `soma_lfe_task_tests` cases.
   - Map documentation behavior to `soma_lfe_task_doc_tests` cases.
   - Link it from the README contract-doc index.

4. Add focused documentation tests, without broad wording locks:
   - Extend `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl` for public docs,
     mirrors, roadmap/status docs, AGENTS, `docs/lisp-messages.md`, Chinese reading
     list, and README contract link.
   - Add `apps/soma_lfe/test/soma_lfe_task_contract_doc_tests.erl` to pin
     `docs/contracts/task-form-test-contract.md` to the compile and documentation
     proof modules/cases.
   - Update site test scripts for the changed pages so rendered HTML contains the
     new public task-surface tokens. For the quick-start criterion, the EUnit
     extraction/compile test is the primary proof; the site script remains the
     build-output smoke.

Do not change `soma_lfe`, `soma_lfe_parser`, `soma_cli`, `soma_cli_server`, or any
runtime/actor behavior. If a doc sentence currently says detached run support uses
`(detach)` inside `(run ...)`, keep that true unless the code changes in a later
issue; this issue should not imply a CLI protocol change.

## Acceptance criteria → tests

| Acceptance criterion | Test mapping |
| --- | --- |
| `site/src/content/docs/start/quick-start.md` workflow example compiles through `soma_lfe:compile/2` as `(task ...)` | Add `soma_lfe_task_doc_tests:test_site_quick_start_task_example_compiles`: extract the `pipeline.lfe` heredoc from the site quick-start, assert it starts with `(task`, compile it, and assert `read`, `process`, `write` steps lower to the expected map shape. Keep/update `site/test/start-quick-start.sh` as rendered build smoke. |
| `docs/cli.md` shows `(task ...)` as the first run request form in the request-form reference | Add `soma_lfe_task_doc_tests:test_cli_request_reference_lists_task_before_run`: read the `## Lisp Request Forms` section and assert `(task` appears before `(run` and before `(ask`. |
| `docs/usage.md` names `(task ...)` in the local CLI wire summary for run requests | Add `soma_lfe_task_doc_tests:test_usage_wire_summary_names_task_run_requests`: read the local CLI wire paragraph and assert it names `(task ...)` plus compatibility `(run ...)`. |
| `docs/roadmap.md` marks bounded Soma Lisp v1 with the public task surface as built | Add `soma_lfe_task_doc_tests:test_roadmap_marks_bounded_soma_lisp_v1_built`: assert `bounded Soma Lisp v1`, `public task surface`, and `[done]` appear in the Lisp track. |
| `site/src/content/docs/reference/roadmap.md` marks bounded Soma Lisp v1 with the public task surface as built | Add `soma_lfe_task_doc_tests:test_site_roadmap_marks_bounded_soma_lisp_v1_built` against the site source; update `site/test/reference-roadmap.sh` to assert a rendered token such as `bounded Soma Lisp v1`. |
| `AGENTS.md` names the bounded Soma Lisp v1 public task surface in the current Lisp state | Add `soma_lfe_task_doc_tests:test_agents_names_public_task_surface`: assert `AGENTS.md` contains the bounded Soma Lisp v1/public task-surface phrase near the Lisp state. |
| `docs/lisp-messages.md` lists `(task ...)` in the implemented grammar table | Add `soma_lfe_task_doc_tests:test_lisp_messages_grammar_lists_task_form`: assert the grammar section contains `(task ...)` and `#{run => #{steps => [...]}}`. |
| `docs/lisp-messages.md` records bounded Soma Lisp v1 as a built slice | Add `soma_lfe_task_doc_tests:test_lisp_messages_records_bounded_soma_lisp_v1_slice`: assert the slices section contains `bounded Soma Lisp v1` and `[done]`. |
| `docs/zh/what-is-soma.zh.md` points readers to the task-form contract from its contract-docs reading list | Add `soma_lfe_task_doc_tests:test_zh_overview_links_task_form_contract`: assert the reading list contains `../contracts/task-form-test-contract.md`. |
| Task-form contract covers compile behavior from `soma_lfe_task_tests` | Add `soma_lfe_task_contract_doc_tests:test_contract_names_task_compile_cases`: assert `docs/contracts/task-form-test-contract.md` names `soma_lfe_task_tests` and representative compile/diagnostic cases, including `test_task_compiles_to_run_steps`, `test_bare_from_lowers_to_from_step`, `test_field_from_lowers_to_from_step_tuple`, `test_timeout_ms_lowers_to_step_timeout_ms`, `test_duplicate_binding_returns_diagnostic`, `test_forward_from_binding_returns_diagnostic`, and `test_unsupported_task_control_heads_return_diagnostic`. |
| Task-form contract covers documentation behavior from `soma_lfe_task_doc_tests` | Add `soma_lfe_task_contract_doc_tests:test_contract_names_task_doc_cases`: assert the contract names `soma_lfe_task_doc_tests` and the doc-proof cases added/kept for README, CLI, usage, roadmap, AGENTS, lisp messages, Chinese docs, site mirrors, and README contract link. |
| `README.md` links the task-form contract from the contract-docs index | Add `soma_lfe_task_doc_tests:test_readme_links_task_form_contract`: read README's "Test contracts" section and assert it links `docs/contracts/task-form-test-contract.md`. |
| `site/src/content/docs/guides/lfe-dsl.md` presents `(task ...)` as the public static task form | Add `soma_lfe_task_doc_tests:test_site_lfe_dsl_documents_task_as_public_static_form`; update `site/test/guide-lfe-dsl.sh` to assert rendered `public static task form`. |
| `site/src/content/docs/guides/lfe-dsl.md` presents `(run ...)` as the compatibility/core run form | Add `soma_lfe_task_doc_tests:test_site_lfe_dsl_documents_run_as_compatibility_core_form`; update `site/test/guide-lfe-dsl.sh` to assert rendered `compatibility/core run form`. |
| `site/src/content/docs/guides/cli.md` describes `soma run WORKFLOW` input as Soma Lisp source with `(task ...)` as the public static task form | Add `soma_lfe_task_doc_tests:test_site_cli_run_workflow_names_soma_lisp_task_source`; update `site/test/guide-cli.sh` to assert rendered tokens `Soma Lisp source` and `(task`. |
| `site/src/content/docs/guides/usage.md` names `(task ...)` in the local CLI wire summary for run requests | Add `soma_lfe_task_doc_tests:test_site_usage_wire_summary_names_task_run_requests`; update `site/test/guide-usage.sh` to assert rendered `(task` or `public static task form`. |

Recommended local verification for the implementation stage:

```bash
rebar3 eunit --module=soma_lfe_task_tests
rebar3 eunit --module=soma_lfe_task_doc_tests
rebar3 eunit --module=soma_lfe_task_contract_doc_tests
site/test/start-quick-start.sh
site/test/guide-lfe-dsl.sh
site/test/guide-cli.sh
site/test/guide-usage.sh
site/test/reference-roadmap.sh
```

The full merge gate remains `rebar3 eunit && rebar3 ct`. The site scripts are
additional documentation-rendering checks for changed site pages.

## Risks & trade-offs

- `(task ...)` and `(run ...)` currently compile to the same run map, but only
  `(run ...)` carries the existing `(detach)` marker in the compatibility/core
  form. Documentation should not imply a CLI protocol change for detach.
- Site scripts that run `npm ci && npm run build` are slower than EUnit doc
  tests. Keep EUnit as the precise acceptance proof and use site scripts only to
  prove mirrored pages still build and render the expected public tokens.
- Substring doc tests can become brittle if they lock large prose blocks. Prefer
  short, semantically load-bearing tokens and section-local ordering checks.
- The new contract doc should not be named as L.6 unless the project wants to
  extend the historical L.1-L.5 track. This issue is better described as bounded
  Soma Lisp v1 / task-form contract because it aligns the public workflow surface,
  not a new actor-message behavior slice.
