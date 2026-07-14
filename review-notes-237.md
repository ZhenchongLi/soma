### Claude

## Verdict

approve

## Real issues

None.

## Questions

None.

## Nits

None.

## Functional evidence

`bash site/test/current-product-surface.sh` ran `npm ci`, built the production site, and reported 27 PASS lines. Astro preview returned HTTP 200 for all six reviewed routes. `rebar3 eunit` passed 387 tests, `rebar3 ct` passed 425 tests, and the focused `soma_cli_main_tests` run passed 6 tests. `rebar3 release` assembled executable `bin/soma` and `bin/somad` entries. A cold packaged `bin/soma run` completed a `.lisp` task, wrote the expected `hi soma` bytes, and its correlation trace contained `run.completed`.

- Criterion 1 — pass: - [x] The built landing product copy names the release's packaged `bin/soma` command as the public entry point. — `test_landing_names_packaged_bin_soma_entry_point` matched the exact statement in `site/dist/index.html` (SHA-256 `47ebd5a67f98e62a87d38cca3fbb784fac00ebab508a38b84e9240ff0956cc61`), and `/` returned HTTP 200.
- Criterion 2 — pass: - [x] The built landing product copy presents Soma Lisp `.lisp` task files as deterministic `soma run` input. — `test_landing_presents_lisp_task_files_as_run_input` matched `.lisp`, deterministic `soma run`, and `(task ...)` in the built landing artifact.
- Criterion 3 — pass: - [x] The built landing product copy presents boot auto-resume as shipped behavior for interrupted durable runs. — `test_landing_marks_boot_auto_resume_shipped` matched the safe-resume statement and unsafe-state fail-safe in the built landing; `soma_run_auto_resume_SUITE` passed in Common Test.
- Criterion 4 — pass: - [x] The built landing product copy presents config-registered CLI tools as a shipped extension path. — `test_landing_marks_config_registered_cli_tools_shipped` matched the shipped `(tool ...)` and `~/.soma/tools/` extension-path statement in the built landing.
- Criterion 5 — pass: - [x] The built landing quick start reproduces the README checkout flow from `rebar3 release` through `_build/default/rel/somad/bin/soma` to `soma trace` with a `.lisp` `(task ...)` source. — `test_landing_quick_start_matches_readme_checkout_flow` matched the ordered flow and the complete one-line `printf 'hi soma\n'` command; the packaged flow returned `(status completed)`, wrote 8 expected bytes, and traced `run.completed`.
- Criterion 6 — pass: - [x] The built landing quick start labels deterministic `soma run` as model-free. — `test_landing_labels_run_model_free` matched `Deterministic soma run is model-free.` in the built landing.
- Criterion 7 — pass: - [x] The built Quick Start page uses the README's `.lisp` pipeline filename. — `test_quick_start_uses_pipeline_lisp` found both `pipeline.lisp` commands and rejected the old `pipeline.lfe` path in `site/dist/start/quick-start/index.html` (SHA-256 `7b421dfa363c81e719ca0ce145081ec82f2c4dd7cdc705019dd515c165911b4e`); the route returned HTTP 200.
- Criterion 8 — pass: - [x] The built Tools page describes `soma_tool_registry:catalog/0` as the model-facing `description`/`params` surface. — `test_tools_documents_model_facing_catalog` matched the exact projection in `site/dist/concepts/tools/index.html` (SHA-256 `edf3bbb1890b8ea62d42f45bef8b707b420d2152d246c8879e7f65a5677b3e98`), and the registry catalog EUnit proofs passed.
- Criterion 9 — pass: - [x] The built Tools page traces `~/.soma/tools/*.lisp` manifests through `soma_tool_manifest:normalize/1` into the registry. — `test_tools_documents_config_manifest_registration_path` found those path fragments in order; `soma_tool_config_SUITE` passed its real loader-to-registry cases.
- Criterion 10 — pass: - [x] The built Tools page explains whole-argument `argv` placeholders for declared params. — `test_tools_documents_whole_argument_placeholders` matched complete-element replacement, the declared-param requirement, and the no-substring rule; all seven `soma_cli_placeholder_SUITE` cases passed.
- Criterion 11 — pass: - [x] The built Tools page lists `state`/`false`/30000 ms as the omitted config-tool defaults. — `test_tools_documents_config_tool_defaults` matched all three defaults in one generated paragraph, and `test_safety_defaults_and_declared_values` passed in Common Test.
- Criterion 12 — pass: - [x] The built Tools page presents `ask_actor` as an actor-owned registered tool. — `test_tools_documents_actor_owned_ask_actor` matched actor ownership and boot registration; `ask_actor_registered_after_app_boot_test` and `soma_tool_ask_actor_SUITE` passed.
- Criterion 13 — pass: - [x] The built CLI guide traces `soma tool register <file>` from immediate live registration to normalized persistence under `~/.soma/tools/` to boot reload. — `test_cli_documents_live_register_persist_reload` found persistence, live registration, rollback guarantees, and boot reload in `site/dist/guides/cli/index.html` (SHA-256 `611f2faf1de408009f85a8ee3cfbc653234d3262f6f456aa62ba00360e491c29`); the packaged tool-verb EUnit proof passed from a cold socket.
- Criterion 14 — pass: - [x] The built CLI guide lists `name`/`effect`/`idempotent`/`adapter`/optional `description` as the `soma tool list` output. — `test_cli_documents_tool_list_fields` matched all five fields in the built guide, and `soma_tool_management_SUITE:test_list_returns_summary_fields` passed.
- Criterion 15 — pass: - [x] The built CLI guide traces `soma tool remove <name>` from immediate live removal to owned-file deletion to post-restart absence. — `test_cli_documents_live_remove_delete_restart` matched owned-file deletion, live removal, failure consistency, and post-restart absence; `test_restart_after_remove_stays_unresolved` passed.
- Criterion 16 — pass: - [x] The built CLI guide identifies built-in-name protection as a tool-management invariant. — `test_cli_documents_builtin_name_protection` matched the protected-name invariant, while the register and remove built-in rejection cases passed in `soma_tool_management_SUITE`.
- Criterion 17 — pass: - [x] The built Decision Layer page describes `[llm] plan = true` as the shipped OpenAI-compatible path to gated `(run-steps ...)` execution. — `test_decision_layer_documents_configured_planning_path` found config, compilation, normalization, policy, budget, and actor-owned execution in `site/dist/concepts/decision-layer/index.html` (SHA-256 `3c5f23b920fb9f0f4583c26c8b9dfdc50517bc9c3390babe08b84f8cde1cf838`); the real-response planning cases passed.
- Criterion 18 — pass: - [x] The built Decision Layer page identifies fixed provider responses as the network-free planning gate. — `test_decision_layer_documents_fixed_response_gate` matched the fixed-response/no-socket statement; `test_cli_planning_tests_use_fixed_provider_response_seam` and the real-provider no-socket proofs passed.
- Criterion 19 — pass: - [x] The built Decision Layer page locates `SOMA_LLM_API_KEY` in the daemon environment. — `test_decision_layer_places_api_key_in_daemon_environment` matched the daemon-starting environment statement in the built Decision Layer page, which returned HTTP 200.
- Criterion 20 — pass: - [x] The built Roadmap marks the CLI/config structured-planning surface as shipped. — `test_roadmap_marks_cli_config_planning_shipped` matched the completed provider, actor-planning, and CLI/config-planning entry in `site/dist/reference/roadmap/index.html` (SHA-256 `d57ffbac58058f966a6a0d154a0ae5abfea73a1b463fcd93ae46f12fc256b68b`).
- Criterion 21 — pass: - [x] The built Roadmap records the shipped tools track from manifest v2 through `ask_actor`. — `test_roadmap_marks_tool_track_shipped` matched manifest v2, `catalog/0`, config tools, the planning prompt, and `ask_actor`; `test_roadmap_keeps_unshipped_tool_slices_open` kept T.3 deferred and T.5 future.
- Criterion 22 — pass: - [x] The built Roadmap records live config-tool management as shipped. — `test_roadmap_marks_live_tool_management_shipped` matched the completed `register` / `list` / `remove` entry, and `test_roadmap_labels_completed_tracks` rejected the old `building now` heading.
