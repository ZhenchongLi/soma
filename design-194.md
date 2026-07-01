# [cc] Align public docs around Soma Lisp tasks, not workflows

## Current state

Bounded Soma Lisp v1 made `(task ...)` the public static task form for `soma run`.
The compiler still accepts `(run ...)` as the compatibility/core form for callers
that need canonical step lists.

The public docs do not yet tell that story cleanly. The README quick start already
shows a `(task ...)` example, but it calls the format a workflow language. The
README docs index still points users at `docs/usage.md` for workflow files.
`docs/usage.md`, `docs/lfe-dsl.md`, `docs/cli.md`, `docs/lisp-messages.md`, and
`docs/release.md` still use workflow wording in user-facing `soma run` paths.
The site guide pages are separate Markdown copies, so they carry the same drift.

The CLI demo inputs under `examples/cli-demo/` are still top-level `(run ...)`
forms. They are valid compatibility inputs, but they no longer match the public
task-first surface. The task-form contract already pins some task-form docs, but
it does not name proof tests for this alignment issue or for the CLI demo files.

## Approach

Keep behavior unchanged. This issue is a documentation and examples alignment
pass.

Use task-first wording anywhere the docs describe public `soma run` input. The
preferred noun is "Soma Lisp task source" when the text names the bytes passed to
`soma run`. Use "task file" for a file path and "task source path" for `-`.
Keep `(run ...)` documented as the compatibility/core form. Keep internal
workflow-engine wording only where it names a design boundary or a non-goal.

Update the source docs first:

- `README.md` quick start and docs index.
- `docs/usage.md` public `soma run` sections and stdin example.
- `docs/lfe-dsl.md` public task headings and the main example.
- `docs/cli.md` opening text and stdin section.
- `docs/lisp-messages.md` `soma run` input description.
- `docs/release.md` sample `soma run` command comment.
- `docs/contracts/cli-test-contract.md`.
- `docs/contracts/cli-1b-test-contract.md`.
- `docs/contracts/task-form-test-contract.md`.

Then update the site copies to mirror the same wording:

- `site/src/content/docs/start/quick-start.md`.
- `site/src/content/docs/guides/lfe-dsl.md`.
- `site/src/content/docs/guides/cli.md`.
- `site/src/content/docs/guides/release.md`.

Convert every user-facing `.lfe` file in `examples/cli-demo/` from top-level
`(run ...)` to top-level `(task ...)`. Preserve the same tool names, args, and
timeouts so the compiled step lists are equivalent. Update the demo README and
script narration from workflow wording to task wording.

Add source-text EUnit tests in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`
for the public-doc, site-doc, contract-doc, demo README, and demo script wording.
Add one compiler test in the same module that reads every `examples/cli-demo/*.lfe`
file, asserts the source starts with `(task`, and passes it to production
`soma_lfe:compile/2`.

Extend `apps/soma_lfe/test/soma_lfe_task_contract_doc_tests.erl` so the task-form
contract names the new proof tests. That keeps the contract file aligned with the
test suite names Dev adds for this issue.

## Acceptance criteria → tests

### Criterion 1 — README quick start names task source
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the README quick-start section.
- Test: `test_readme_quick_start_names_soma_run_input_task_source` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 2 — README docs index points to task files
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the README Docs section.
- Test: `test_readme_docs_index_calls_usage_task_file_guide` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 3 — usage guide uses task wording for public run sections
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `docs/usage.md` and checks the public `soma run` sections.
- Test: `test_usage_doc_uses_task_wording_for_public_run_sections` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 4 — usage stdin example uses task form
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the `docs/usage.md` stdin section.
- Test: `test_usage_stdin_example_uses_task_form` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 5 — LFE DSL public headings use task wording
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `docs/lfe-dsl.md`.
- Test: `test_lfe_dsl_public_headings_use_task_wording` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 6 — LFE DSL main example uses task form
- Call chain: none (direct source-file read)
- Test entry: EUnit extracts the main example from `docs/lfe-dsl.md`.
- Test: `test_lfe_dsl_main_example_uses_task_form` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 7 — CLI opening names task files
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the opening paragraph of `docs/cli.md`.
- Test: `test_cli_opening_calls_input_task_files` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 8 — CLI stdin section names dash as task source path
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the stdin section of `docs/cli.md`.
- Test: `test_cli_stdin_section_names_dash_task_source_path` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 9 — Lisp messages names task source
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `docs/lisp-messages.md`.
- Test: `test_lisp_messages_soma_run_input_is_task_source` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 10 — release sample names task execution
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the sample command block in `docs/release.md`.
- Test: `test_release_sample_run_command_is_task_execution` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 11 — site quick start presents public tasks
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `site/src/content/docs/start/quick-start.md`.
- Test: `test_site_quick_start_presents_soma_lisp_tasks` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 12 — site LFE DSL mirrors task-first wording
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `site/src/content/docs/guides/lfe-dsl.md`.
- Test: `test_site_lfe_dsl_mirrors_task_first_wording` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 13 — site CLI mirrors task-first wording
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `site/src/content/docs/guides/cli.md`.
- Test: `test_site_cli_mirrors_task_first_wording` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 14 — site release mirrors task wording
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `site/src/content/docs/guides/release.md`.
- Test: `test_site_release_mirrors_task_wording` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 15 — CLI demo files compile as tasks
- Call chain: user shell -> `soma_cli_main:dispatch/1` -> `soma_cli:run/1` -> `soma_cli_server:handle_lisp_request/4` -> `soma_lfe:compile/2`
- Test entry: `soma_lfe:compile/2`, because this criterion is about demo source shape and compiler acceptance rather than daemon execution.
- Test: `test_cli_demo_lfe_files_compile_as_top_level_tasks` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 16 — CLI demo README names task files
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `examples/cli-demo/README.md`.
- Test: `test_cli_demo_readme_describes_inputs_as_task_files` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 17 — CLI demo script names task run
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `examples/cli-demo/demo.sh`.
- Test: `test_cli_demo_script_describes_task_run` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 18 — CLI contract names task source
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `docs/contracts/cli-test-contract.md`.
- Test: `test_cli_contract_describes_run_request_as_task_source` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 19 — CLI.1b contract names file input as task source
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the file-input rows in `docs/contracts/cli-1b-test-contract.md`.
- Test: `test_cli_1b_contract_describes_file_run_input_as_task_source` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 20 — CLI.1b contract names stdin input as task source
- Call chain: none (direct source-file read)
- Test entry: EUnit reads the stdin row in `docs/contracts/cli-1b-test-contract.md`.
- Test: `test_cli_1b_contract_describes_stdin_run_input_as_task_source` in `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl`

### Criterion 21 — task-form contract names wording proof tests
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `docs/contracts/task-form-test-contract.md`.
- Test: `test_contract_names_task_wording_doc_cases` in `apps/soma_lfe/test/soma_lfe_task_contract_doc_tests.erl`

### Criterion 22 — task-form contract names demo proof test
- Call chain: none (direct source-file read)
- Test entry: EUnit reads `docs/contracts/task-form-test-contract.md`.
- Test: `test_contract_names_cli_demo_task_case` in `apps/soma_lfe/test/soma_lfe_task_contract_doc_tests.erl`

## Risks & trade-offs

Most tests are source-text assertions. They are brittle if later copy changes pick
different words. That is acceptable here because the issue is about exact public
terminology.

The site docs are separate copies, not generated from `docs/`. This design keeps
them in sync by testing the site source Markdown. It does not add a sync tool.

The demo compile test proves the `.lfe` files are accepted as top-level tasks. It
does not execute the demo script. That keeps this slice away from release and
daemon behavior, which the issue leaves out of scope.
