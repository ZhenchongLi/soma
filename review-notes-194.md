# Review notes for #194

### Claude

## Verdict

Needs changes.

The branch gets the main hotspots and the proof tests are green, but the public
docs are still not consistently task-first. This is a docs alignment issue, so
leaving user-facing "workflow" nouns in the same `soma run` path is not a small
cosmetic miss; it is the thing this branch was supposed to eliminate.

Verification run:

- `rebar3 eunit --module=soma_lfe_task_doc_tests --module=soma_lfe_task_contract_doc_tests`: 39 tests, 0 failures.
- `rebar3 eunit`: 337 tests, 0 failures.
- `rebar3 ct`: All 350 tests passed.

## Real issues

1. Public `soma run` docs still call the public surface workflows in several
   places.

   Concrete examples:

   - `docs/lfe-dsl.md:3` says the public language is for "`soma run` workflow
     files".
   - `docs/lfe-dsl.md:22` says `(task ...)` is the public static task form for
     "bounded Soma Lisp workflows".
   - `docs/usage.md:495` still introduces "Useful workflow files", and
     `docs/usage.md:507` points to `lfe-dsl.md` for "workflow language syntax".
   - `docs/cli.md:228` says "Use `soma run` workflows for deterministic tool
     work."
   - `site/src/content/docs/guides/lfe-dsl.md:42` mirrors "bounded Soma Lisp
     workflows".

   These are reader-facing docs around the public CLI/task source, not internal
   implementation commentary. The tests pass because they assert selected
   paragraphs instead of guarding the public docs as a whole. Fix the stale text
   and add a coarse source-text proof over the changed public docs if the intent
   is to stop this drift.

## Questions

None.

## Nits

- `docs/lfe-dsl.md:30` and `site/src/content/docs/guides/lfe-dsl.md:50` add the
  same long single-line sentence. Not a blocker, just hard to review.

## Functional evidence

- The README quick start calls the public soma run input a Soma Lisp task source, not a workflow language.
  Evidence: `README.md:140` says "That file is the public `soma run` input: a Soma Lisp task source." Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:125` (`test_readme_quick_start_names_soma_run_input_task_source`).

- The README docs index calls docs/usage.md the guide for running task files, not workflow files.
  Evidence: `README.md:301` to `README.md:303` describes `docs/usage.md` as "running task files". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:134` (`test_readme_docs_index_calls_usage_task_file_guide`).

- docs/usage.md uses task wording for the public soma run guide sections.
  Evidence: `docs/usage.md:3` says "running task files", `docs/usage.md:42` says "Quick Start: Run A Task", `docs/usage.md:81` says "Task Files", and `docs/usage.md:83` says public `soma run` input is Soma Lisp task source. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:146` (`test_usage_doc_uses_task_wording_for_public_run_sections`).

- docs/usage.md shows (task ...) in the stdin example.
  Evidence: `docs/usage.md:132` names `-` as the task source path and `docs/usage.md:135` pipes a `(task ...)` form into `$SOMA run -`. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:175` (`test_usage_stdin_example_uses_task_form`).

- docs/lfe-dsl.md uses task wording for public task headings.
  Evidence: `docs/lfe-dsl.md:20` says "Public static task form", `docs/lfe-dsl.md:56` says "Task Files", and `docs/lfe-dsl.md:137` says "Task Example". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:183` (`test_lfe_dsl_public_headings_use_task_wording`). See Real issues for remaining stale prose in this file.

- The main example in docs/lfe-dsl.md uses (task ...) as its source form.
  Evidence: `docs/lfe-dsl.md:143` to `docs/lfe-dsl.md:155` creates `pipeline.lfe` with top-level `(task ...)`. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:193` (`test_lfe_dsl_main_example_uses_task_form`).

- docs/cli.md opening text calls the command input Soma Lisp task files.
  Evidence: `docs/cli.md:3` says "`soma` is the user command. It reads Soma Lisp task files". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:382` (`test_cli_opening_calls_input_task_files`).

- The docs/cli.md stdin section names - as the task source path.
  Evidence: `docs/cli.md:83` to `docs/cli.md:88` has "Read From Stdin", "Use `-` as the task source path", and a `(task ...)` stdin example. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:393` (`test_cli_stdin_section_names_dash_task_source_path`).

- docs/lisp-messages.md describes soma run input as task source instead of a .lfe workflow.
  Evidence: `docs/lisp-messages.md:44` says "`soma run` takes Soma Lisp task source **only**". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:288` (`test_lisp_messages_soma_run_input_is_task_source`).

- docs/release.md describes the sample soma run command as task execution.
  Evidence: `docs/release.md:61` comments `/opt/soma/bin/soma run flow.lfe` as "run a task under supervision". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:296` (`test_release_sample_run_command_is_task_execution`).

- The site quick-start page presents Soma Lisp tasks as the public soma run concept.
  Evidence: `site/src/content/docs/start/quick-start.md:3` says "Soma Lisp task files", `site/src/content/docs/start/quick-start.md:20` says "Run a task", and `site/src/content/docs/start/quick-start.md:22` says a Soma Lisp task is the public source form for `soma run`. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:93` (`test_site_quick_start_presents_soma_lisp_tasks`).

- The site LFE DSL guide mirrors task-first wording from docs/lfe-dsl.md.
  Evidence: `site/src/content/docs/guides/lfe-dsl.md:52` says "Task Files", `site/src/content/docs/guides/lfe-dsl.md:128` says "Task Example", and `site/src/content/docs/guides/lfe-dsl.md:134` to `site/src/content/docs/guides/lfe-dsl.md:146` uses top-level `(task ...)`. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:253` (`test_site_lfe_dsl_mirrors_task_first_wording`). See Real issues for remaining stale prose in this file.

- The site CLI guide mirrors task-first wording from docs/cli.md.
  Evidence: `site/src/content/docs/guides/cli.md:94` uses `soma run <task-file>`, and `site/src/content/docs/guides/cli.md:105` to `site/src/content/docs/guides/cli.md:110` documents `TASK_FILE` and `-` as task source path. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:411` (`test_site_cli_mirrors_task_first_wording`).

- The site release guide mirrors task wording from docs/release.md.
  Evidence: `site/src/content/docs/guides/release.md:65` comments `/opt/soma/bin/soma run flow.lfe` as "run a task under supervision". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:310` (`test_site_release_mirrors_task_wording`).

- Every user-facing CLI demo .lfe file under examples/cli-demo/ compiles through production soma_lfe:compile/2 from top-level (task ...) source.
  Evidence: `examples/cli-demo/crash.lfe:1`, `examples/cli-demo/pipeline.lfe:1`, `examples/cli-demo/slow.lfe:1`, and `examples/cli-demo/timeout.lfe:1` are all top-level `(task ...)`. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:473` (`test_cli_demo_lfe_files_compile_as_top_level_tasks`) reads every `examples/cli-demo/*.lfe` file and calls production `soma_lfe:compile/2`; EUnit passed.

- The CLI demo README describes demo inputs as task files, not workflow files.
  Evidence: `examples/cli-demo/README.md:62` says "The task files" and `examples/cli-demo/README.md:41` says "The same Lisp you write task files in". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:488` (`test_cli_demo_readme_describes_inputs_as_task_files`).

- The CLI demo script narration describes the scripted run as a task run, not a workflow run.
  Evidence: `examples/cli-demo/demo.sh:59` says "a supervised multi-step task run" and `examples/cli-demo/demo.sh:60` titles the beat "run a task". Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:498` (`test_cli_demo_script_describes_task_run`).

- docs/contracts/cli-test-contract.md describes the soma run request source as Soma Lisp task source.
  Evidence: `docs/contracts/cli-test-contract.md:19` says "The `soma run` request source is Soma Lisp task source." Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:512` (`test_cli_contract_describes_run_request_as_task_source`).

- docs/contracts/cli-1b-test-contract.md describes file soma run input as Soma Lisp task source.
  Evidence: `docs/contracts/cli-1b-test-contract.md:11` to `docs/contracts/cli-1b-test-contract.md:12` says `soma run flow.lfe` reads Soma Lisp task source from the file, and `docs/contracts/cli-1b-test-contract.md:54` pins the file-input proof row. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:522` (`test_cli_1b_contract_describes_file_run_input_as_task_source`).

- docs/contracts/cli-1b-test-contract.md describes stdin soma run input as Soma Lisp task source.
  Evidence: `docs/contracts/cli-1b-test-contract.md:56` says `soma_cli:run/1` reads Soma Lisp task source from stdin and that stdin `soma run` input is Soma Lisp task source. Proof test: `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:537` (`test_cli_1b_contract_describes_stdin_run_input_as_task_source`).

- docs/contracts/task-form-test-contract.md names the doc proof tests for this task-wording alignment.
  Evidence: `docs/contracts/task-form-test-contract.md:45` to `docs/contracts/task-form-test-contract.md:73` names the task-wording documentation contract and its proof tests. Proof test: `apps/soma_lfe/test/soma_lfe_task_contract_doc_tests.erl:65` (`test_contract_names_task_wording_doc_cases`).

- docs/contracts/task-form-test-contract.md names the demo proof test for top-level (task ...) CLI demo files.
  Evidence: `docs/contracts/task-form-test-contract.md:68` names `test_cli_demo_lfe_files_compile_as_top_level_tasks`. Proof test: `apps/soma_lfe/test/soma_lfe_task_contract_doc_tests.erl:101` (`test_contract_names_cli_demo_task_case`).
