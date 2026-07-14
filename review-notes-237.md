### Claude

## Verdict

changes-requested

## Real issues

1. `site/src/content/docs/guides/cli.md:8-14` adds `tool register`, `tool list`, and `tool remove` to the packaged client surface, then says a client command auto-starts the daemon. `apps/soma_actor/src/soma_cli_main.erl:195-200` only auto-starts for `run`, `ask`, `status`, `cancel`, and `trace`. A cold `_build/default/rel/somad/bin/soma tool list --socket <missing>` exits 1 with `{badmatch,{error,enoent}}` and creates no socket. The advertised first command crashes. Auto-start the tool verbs or document the running-daemon precondition. Add a release-path regression test.

2. `site/src/content/docs/reference/roadmap.md:43` marks the entire tool abstraction track `[done]`. `docs/roadmap.md:386-399` says T.3 memory is deferred and T.5 MCP is later work. `design-237.md:114-121` requires both to stay visibly open or deferred. The public Roadmap now calls unshipped work shipped. List the completed slices without marking the whole track done, preserve the T.3 and T.5 statuses, and pin those statuses in the built-copy test.

## Questions

None.

## Nits

None.

## Functional evidence

`site/test/current-product-surface.sh` rebuilt the production site and printed 25 PASS lines. `rebar3 release` assembled `_build/default/rel/somad`. EUnit passed 386 tests and Common Test passed 425 tests. Astro preview served all six reviewed routes with HTTP 200.

- Criterion 1 — pass: - [x] The built landing product copy names the release's packaged `bin/soma` command as the public entry point. — `test_landing_names_packaged_bin_soma_entry_point` matched the public-entry-point sentence in `site/dist/index.html`; `/` returned HTTP 200.
- Criterion 2 — pass: - [x] The built landing product copy presents Soma Lisp `.lisp` task files as deterministic `soma run` input. — `test_landing_presents_lisp_task_files_as_run_input` matched the `.lisp`, deterministic `soma run`, and `(task ...)` statement in `site/dist/index.html`.
- Criterion 3 — pass: - [x] The built landing product copy presents boot auto-resume as shipped behavior for interrupted durable runs. — `test_landing_marks_boot_auto_resume_shipped` matched the shipped safe-resume statement and non-idempotent-state fail-safe in `site/dist/index.html`.
- Criterion 4 — pass: - [x] The built landing product copy presents config-registered CLI tools as a shipped extension path. — `test_landing_marks_config_registered_cli_tools_shipped` matched the shipped `(tool ...)` and `~/.soma/tools/` extension path in `site/dist/index.html`.
- Criterion 5 — pass: - [x] The built landing quick start reproduces the README checkout flow from `rebar3 release` through `_build/default/rel/somad/bin/soma` to `soma trace` with a `.lisp` `(task ...)` source. — `test_landing_quick_start_matches_readme_checkout_flow` found the six required fragments in order in `site/dist/index.html`; the served file had SHA-256 `4cbb942f544f7c0d868f7fbbd860d0a56019fee239199a5e67e7622ab7893fc9`.
- Criterion 6 — pass: - [x] The built landing quick start labels deterministic `soma run` as model-free. — `test_landing_labels_run_model_free` matched `Deterministic soma run is model-free.` in `site/dist/index.html`.
- Criterion 7 — pass: - [x] The built Quick Start page uses the README's `.lisp` pipeline filename. — `test_quick_start_uses_pipeline_lisp` found both `pipeline.lisp` commands and rejected `/tmp/soma-demo/pipeline.lfe` in `site/dist/start/quick-start/index.html`; the route returned HTTP 200.
- Criterion 8 — pass: - [x] The built Tools page describes `soma_tool_registry:catalog/0` as the model-facing `description`/`params` surface. — `test_tools_documents_model_facing_catalog` matched the exact catalog projection in `site/dist/concepts/tools/index.html`; the route returned HTTP 200.
- Criterion 9 — pass: - [x] The built Tools page traces `~/.soma/tools/*.lisp` manifests through `soma_tool_manifest:normalize/1` into the registry. — `test_tools_documents_config_manifest_registration_path` found those three path fragments in order in `site/dist/concepts/tools/index.html`.
- Criterion 10 — pass: - [x] The built Tools page explains whole-argument `argv` placeholders for declared params. — `test_tools_documents_whole_argument_placeholders` matched the full-element replacement, declared-param requirement, and no-substring rule in `site/dist/concepts/tools/index.html`.
- Criterion 11 — pass: - [x] The built Tools page lists `state`/`false`/30000 ms as the omitted config-tool defaults. — `test_tools_documents_config_tool_defaults` matched all three defaults in one generated paragraph in `site/dist/concepts/tools/index.html`.
- Criterion 12 — pass: - [x] The built Tools page presents `ask_actor` as an actor-owned registered tool. — `test_tools_documents_actor_owned_ask_actor` matched the actor-owned boot-registration statement in `site/dist/concepts/tools/index.html`.
- Criterion 13 — pass: - [x] The built CLI guide traces `soma tool register <file>` from immediate live registration to normalized persistence under `~/.soma/tools/` to boot reload. — `test_cli_documents_live_register_persist_reload` found persistence, live registration, failure-state consistency, and boot reload in `site/dist/guides/cli/index.html`; the route returned HTTP 200. Real issue 1 covers the missing cold-start behavior.
- Criterion 14 — pass: - [x] The built CLI guide lists `name`/`effect`/`idempotent`/`adapter`/optional `description` as the `soma tool list` output. — `test_cli_documents_tool_list_fields` matched the five-field statement in `site/dist/guides/cli/index.html`.
- Criterion 15 — pass: - [x] The built CLI guide traces `soma tool remove <name>` from immediate live removal to owned-file deletion to post-restart absence. — `test_cli_documents_live_remove_delete_restart` found owned-file deletion, live removal, failure-state consistency, and post-restart absence in `site/dist/guides/cli/index.html`.
- Criterion 16 — pass: - [x] The built CLI guide identifies built-in-name protection as a tool-management invariant. — `test_cli_documents_builtin_name_protection` matched the protected-name invariant in `site/dist/guides/cli/index.html`.
- Criterion 17 — pass: - [x] The built Decision Layer page describes `[llm] plan = true` as the shipped OpenAI-compatible path to gated `(run-steps ...)` execution. — `test_decision_layer_documents_configured_planning_path` found the path through normalization, policy, budget, and actor-owned execution in `site/dist/concepts/decision-layer/index.html`; the route returned HTTP 200.
- Criterion 18 — pass: - [x] The built Decision Layer page identifies fixed provider responses as the network-free planning gate. — `test_decision_layer_documents_fixed_response_gate` matched the fixed-response and no-socket statement in `site/dist/concepts/decision-layer/index.html`.
- Criterion 19 — pass: - [x] The built Decision Layer page locates `SOMA_LLM_API_KEY` in the daemon environment. — `test_decision_layer_places_api_key_in_daemon_environment` matched the daemon-starting environment statement in `site/dist/concepts/decision-layer/index.html`.
- Criterion 20 — pass: - [x] The built Roadmap marks the CLI/config structured-planning surface as shipped. — `test_roadmap_marks_cli_config_planning_shipped` matched the completed provider, actor-planning, and CLI/config-planning entry in `site/dist/reference/roadmap/index.html`; the route returned HTTP 200.
- Criterion 21 — pass: - [x] The built Roadmap records the shipped tools track from manifest v2 through `ask_actor`. — `test_roadmap_marks_tool_track_shipped` matched manifest v2, `catalog/0`, config tools, the planning prompt, and `ask_actor` in `site/dist/reference/roadmap/index.html`. Real issue 2 covers the false whole-track status.
- Criterion 22 — pass: - [x] The built Roadmap records live config-tool management as shipped. — `test_roadmap_marks_live_tool_management_shipped` matched the completed `register` / `list` / `remove` entry in `site/dist/reference/roadmap/index.html`; `test_roadmap_labels_completed_tracks` rejected the old `building now` heading.
