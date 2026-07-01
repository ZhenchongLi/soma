# Review notes for #194

### Claude

## Verdict

Needs changes.

The branch passes the tests I ran, but it still leaves public `soma run` prose
calling the task source a workflow in multiple places. For an issue whose whole
job is terminology alignment, that is the bug, not a cosmetic nit.

Verification:

- `rebar3 eunit --module=soma_lfe_task_doc_tests --module=soma_lfe_task_contract_doc_tests`: 39 tests, 0 failures.
- `rebar3 eunit`: 337 tests, 0 failures.
- `rebar3 ct`: all 350 tests passed.

## Real issues

1. Public task-source docs still use workflow wording.

   The diff updates the main examples, but reader-facing guide text still says
   public `soma run` inputs are workflows:

   - `docs/lfe-dsl.md:3` to `docs/lfe-dsl.md:4` says this is the public language
     for "`soma run` workflow files".
   - `docs/lfe-dsl.md:22` says `(task ...)` is for "bounded Soma Lisp workflows".
   - `docs/usage.md:405`, `docs/usage.md:472`, `docs/usage.md:495`, and
     `docs/usage.md:507` still use "successful workflow", "The workflow names",
     "Useful workflow files", and "workflow language syntax".
   - `docs/cli.md:228` says "Use `soma run` workflows for deterministic tool
     work."
   - `site/src/content/docs/guides/lfe-dsl.md:42` mirrors the stale "bounded Soma
     Lisp workflows" sentence.

   These are not internal "workflow engine" non-goal notes. They are public docs
   around the CLI task source, exactly the surface this issue is supposed to
   clean up. The current proof tests pass because they check selected snippets,
   not the whole public docs surface that can still drift.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] The README quick start calls the public `soma run` input a Soma Lisp task source, not a workflow language.
  Artifact: `README.md:140` says "That file is the public `soma run` input: a Soma Lisp task source."

- [x] The README docs index calls `docs/usage.md` the guide for running task files, not workflow files.
  Artifact: `README.md:301` to `README.md:303` describes `docs/usage.md` as "running task files".

- [x] `docs/usage.md` uses task wording for the public `soma run` guide sections.
  Artifact: `docs/usage.md:42` and `docs/usage.md:81` use "Run A Task" and "Task Files"; see Real issue 1 for remaining stale public wording in the same guide.

- [x] `docs/usage.md` shows `(task ...)` in the stdin example.
  Artifact: `docs/usage.md:135` pipes a top-level `(task ...)` form into `$SOMA run -`.

- [x] `docs/lfe-dsl.md` uses task wording for public task headings.
  Artifact: `docs/lfe-dsl.md:20`, `docs/lfe-dsl.md:56`, and `docs/lfe-dsl.md:137` use task-form, task-file, and task-example headings.

- [x] The main example in `docs/lfe-dsl.md` uses `(task ...)` as its source form.
  Artifact: `docs/lfe-dsl.md:143` to `docs/lfe-dsl.md:155` writes `pipeline.lfe` with a top-level `(task ...)`.

- [x] `docs/cli.md` opening text calls the command input Soma Lisp task files.
  Artifact: `docs/cli.md:3` says "`soma` is the user command. It reads Soma Lisp task files".

- [x] The `docs/cli.md` stdin section names `-` as the task source path.
  Artifact: `docs/cli.md:85` says "Use `-` as the task source path".

- [x] `docs/lisp-messages.md` describes `soma run` input as task source instead of a `.lfe` workflow.
  Artifact: `docs/lisp-messages.md:44` says "`soma run` takes Soma Lisp task source **only**".

- [x] `docs/release.md` describes the sample `soma run` command as task execution.
  Artifact: `docs/release.md:61` comments `/opt/soma/bin/soma run flow.lfe` as "run a task under supervision".

- [x] The site quick-start page presents Soma Lisp tasks as the public `soma run` concept.
  Artifact: `site/src/content/docs/start/quick-start.md:6`, `site/src/content/docs/start/quick-start.md:20`, and `site/src/content/docs/start/quick-start.md:22` present Soma Lisp task files, "Run a task", and the public source form for `soma run`.

- [x] The site LFE DSL guide mirrors task-first wording from `docs/lfe-dsl.md`.
  Artifact: `site/src/content/docs/guides/lfe-dsl.md:52` and `site/src/content/docs/guides/lfe-dsl.md:128` use "Task Files" and "Task Example"; see Real issue 1 for the stale mirrored workflow sentence.

- [x] The site CLI guide mirrors task-first wording from `docs/cli.md`.
  Artifact: `site/src/content/docs/guides/cli.md:94`, `site/src/content/docs/guides/cli.md:106`, and `site/src/content/docs/guides/cli.md:109` use `<task-file>`, `TASK_FILE`, and "task source path".

- [x] The site release guide mirrors task wording from `docs/release.md`.
  Artifact: `site/src/content/docs/guides/release.md:65` comments `/opt/soma/bin/soma run flow.lfe` as "run a task under supervision".

- [x] Every user-facing CLI demo `.lfe` file under `examples/cli-demo/` compiles through production `soma_lfe:compile/2` from top-level `(task ...)` source.
  Artifact: `examples/cli-demo/crash.lfe:1`, `examples/cli-demo/pipeline.lfe:1`, `examples/cli-demo/slow.lfe:1`, and `examples/cli-demo/timeout.lfe:1` all start with `(task`; `test_cli_demo_lfe_files_compile_as_top_level_tasks` calls production `soma_lfe:compile/2`.

- [x] The CLI demo README describes demo inputs as task files, not workflow files.
  Artifact: `examples/cli-demo/README.md:62` says "The task files" and `examples/cli-demo/README.md:74` says "Task files are Soma Lisp s-exprs".

- [x] The CLI demo script narration describes the scripted run as a task run, not a workflow run.
  Artifact: `examples/cli-demo/demo.sh:60` titles the scripted run "1. run a task: file_read -> echo -> file_write".

- [x] `docs/contracts/cli-test-contract.md` describes the `soma run` request source as Soma Lisp task source.
  Artifact: `docs/contracts/cli-test-contract.md:19` says "The `soma run` request source is Soma Lisp task source."

- [x] `docs/contracts/cli-1b-test-contract.md` describes file `soma run` input as Soma Lisp task source.
  Artifact: `docs/contracts/cli-1b-test-contract.md:54` says `soma_cli:run/1` reads Soma Lisp task source from a `.lfe` file.

- [x] `docs/contracts/cli-1b-test-contract.md` describes stdin `soma run` input as Soma Lisp task source.
  Artifact: `docs/contracts/cli-1b-test-contract.md:56` says stdin `soma run` input is Soma Lisp task source.

- [x] `docs/contracts/task-form-test-contract.md` names the doc proof tests for this task-wording alignment.
  Artifact: `docs/contracts/task-form-test-contract.md:51` to `docs/contracts/task-form-test-contract.md:73` names the task-wording doc proof tests.

- [x] `docs/contracts/task-form-test-contract.md` names the demo proof test for top-level `(task ...)` CLI demo files.
  Artifact: `docs/contracts/task-form-test-contract.md:68` names `test_cli_demo_lfe_files_compile_as_top_level_tasks`.
