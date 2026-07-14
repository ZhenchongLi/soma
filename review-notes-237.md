### Claude

## Verdict

changes-requested

## Real issues

1. `site/src/content/docs/guides/cli.md:229-235` still says the real provider returns only `reply`, `soma ask` does not execute tools, and structured `run_steps` planning has not landed. That is false. This branch documents shipped `[llm] plan = true` execution on the Decision Layer and Roadmap pages. The CLI guide tells operators not to use a shipped path. Replace the paragraph with the current default-reply and opt-in-planning behavior. Add a built-copy assertion that rejects the stale claims.

2. `site/src/content/docs/reference/roadmap.md:39-44` labels every completed track below it as “building now.” Every listed status is `[done]`. The heading contradicts the status refresh this branch adds. Rename the heading and pin the rendered heading in `site/test/current-product-surface.sh`.

## Questions

None.

## Nits

None.

## Functional evidence

`site/test/current-product-surface.sh` built the production site and printed 23 PASS lines. Astro preview served all six target routes with HTTP 200 and byte-identical generated HTML. `rebar3 eunit` passed 386 tests. `rebar3 ct` passed 425 tests.

- Criterion 1 — pass: - [x] The built landing product copy names the release's packaged `bin/soma` command as the public entry point. — `test_landing_names_packaged_bin_soma_entry_point` found the exact sentence in `site/dist/index.html`; `/` returned HTTP 200 with SHA-256 `4cbb942f544f7c0d868f7fbbd860d0a56019fee239199a5e67e7622ab7893fc9`.
- Criterion 2 — pass: - [x] The built landing product copy presents Soma Lisp `.lisp` task files as deterministic `soma run` input. — `test_landing_presents_lisp_task_files_as_run_input` found the `.lisp`, `soma run`, and `(task ...)` statement in `site/dist/index.html`.
- Criterion 3 — pass: - [x] The built landing product copy presents boot auto-resume as shipped behavior for interrupted durable runs. — `test_landing_marks_boot_auto_resume_shipped` found the shipped safe-resume statement and its non-idempotent-state fail-safe in `site/dist/index.html`.
- Criterion 4 — pass: - [x] The built landing product copy presents config-registered CLI tools as a shipped extension path. — `test_landing_marks_config_registered_cli_tools_shipped` found the shipped `(tool ...)` and `~/.soma/tools/` extension path in `site/dist/index.html`.
- Criterion 5 — pass: - [x] The built landing quick start reproduces the README checkout flow from `rebar3 release` through `_build/default/rel/somad/bin/soma` to `soma trace` with a `.lisp` `(task ...)` source. — `test_landing_quick_start_matches_readme_checkout_flow` found the six required fragments in order in `site/dist/index.html`; the served page hash was `4cbb942f544f7c0d868f7fbbd860d0a56019fee239199a5e67e7622ab7893fc9`.
- Criterion 6 — pass: - [x] The built landing quick start labels deterministic `soma run` as model-free. — `test_landing_labels_run_model_free` found `Deterministic soma run is model-free.` in `site/dist/index.html`.
- Criterion 7 — pass: - [x] The built Quick Start page uses the README's `.lisp` pipeline filename. — `test_quick_start_uses_pipeline_lisp` found both `pipeline.lisp` commands and rejected the old `.lfe` path in `site/dist/start/quick-start/index.html`; the route returned HTTP 200 with SHA-256 `f729036ce77ce4f93047b4248ef209dbf83b7969405014e11c0616adcfca6c18`.
- Criterion 8 — pass: - [x] The built Tools page describes `soma_tool_registry:catalog/0` as the model-facing `description`/`params` surface. — `test_tools_documents_model_facing_catalog` found the exact catalog projection in `site/dist/concepts/tools/index.html`; the route returned HTTP 200 with SHA-256 `edf3bbb1890b8ea62d42f45bef8b707b420d2152d246c8879e7f65a5677b3e98`.
- Criterion 9 — pass: - [x] The built Tools page traces `~/.soma/tools/*.lisp` manifests through `soma_tool_manifest:normalize/1` into the registry. — `test_tools_documents_config_manifest_registration_path` found those three path fragments in order in `site/dist/concepts/tools/index.html`.
- Criterion 10 — pass: - [x] The built Tools page explains whole-argument `argv` placeholders for declared params. — `test_tools_documents_whole_argument_placeholders` found the full-element replacement, declared-param requirement, and no-substring rule in `site/dist/concepts/tools/index.html`.
- Criterion 11 — pass: - [x] The built Tools page lists `state`/`false`/30000 ms as the omitted config-tool defaults. — `test_tools_documents_config_tool_defaults` found all three defaults in one generated paragraph in `site/dist/concepts/tools/index.html`.
- Criterion 12 — pass: - [x] The built Tools page presents `ask_actor` as an actor-owned registered tool. — `test_tools_documents_actor_owned_ask_actor` found the actor-owned boot-registration statement in `site/dist/concepts/tools/index.html`.
- Criterion 13 — pass: - [x] The built CLI guide traces `soma tool register <file>` from immediate live registration to normalized persistence under `~/.soma/tools/` to boot reload. — `test_cli_documents_live_register_persist_reload` found validated normalized persistence, live registration, failure-state consistency, and boot reload in `site/dist/guides/cli/index.html`; the route returned HTTP 200 with SHA-256 `3962ffaf9667ac33158332efa8d6c9f17bc65e8320a1d747a833032146511989`.
- Criterion 14 — pass: - [x] The built CLI guide lists `name`/`effect`/`idempotent`/`adapter`/optional `description` as the `soma tool list` output. — `test_cli_documents_tool_list_fields` found the five-field statement in `site/dist/guides/cli/index.html`.
- Criterion 15 — pass: - [x] The built CLI guide traces `soma tool remove <name>` from immediate live removal to owned-file deletion to post-restart absence. — `test_cli_documents_live_remove_delete_restart` found owned-file deletion, live removal, failure-state consistency, and post-restart absence in `site/dist/guides/cli/index.html`.
- Criterion 16 — pass: - [x] The built CLI guide identifies built-in-name protection as a tool-management invariant. — `test_cli_documents_builtin_name_protection` found the protected-name invariant in `site/dist/guides/cli/index.html`.
- Criterion 17 — pass: - [x] The built Decision Layer page describes `[llm] plan = true` as the shipped OpenAI-compatible path to gated `(run-steps ...)` execution. — `test_decision_layer_documents_configured_planning_path` found the configured path through normalization, policy, budget, and actor-owned execution in `site/dist/concepts/decision-layer/index.html`; the route returned HTTP 200 with SHA-256 `3c5f23b920fb9f0f4583c26c8b9dfdc50517bc9c3390babe08b84f8cde1cf838`.
- Criterion 18 — pass: - [x] The built Decision Layer page identifies fixed provider responses as the network-free planning gate. — `test_decision_layer_documents_fixed_response_gate` found the fixed-response and no-socket statement in `site/dist/concepts/decision-layer/index.html`.
- Criterion 19 — pass: - [x] The built Decision Layer page locates `SOMA_LLM_API_KEY` in the daemon environment. — `test_decision_layer_places_api_key_in_daemon_environment` found the daemon-starting environment statement in `site/dist/concepts/decision-layer/index.html`.
- Criterion 20 — fail: - [x] The built Roadmap marks the CLI/config structured-planning surface as shipped. — `site/dist/reference/roadmap/index.html` marks the node B entry `[done]` but places it under `Active tracks (parallel to v0.7+, building now)`, so the rendered status contradicts itself.
- Criterion 21 — fail: - [x] The built Roadmap records the shipped tools track from manifest v2 through `ask_actor`. — `site/dist/reference/roadmap/index.html` contains the complete `[done]` tools entry but puts it under the same `building now` heading.
- Criterion 22 — fail: - [x] The built Roadmap records live config-tool management as shipped. — `site/dist/reference/roadmap/index.html` contains the `[done]` register/list/remove entry but puts it under the same `building now` heading; the served artifact SHA-256 is `76b4fb33c50f5531b3ee24ea7e8d7239af8831658479e43ada1bdb6e538ed239`.
