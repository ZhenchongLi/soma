### Claude

## Verdict

changes-requested

## Real issues

1. `site/src/pages/index.astro:15` puts `\n` inside a JavaScript template literal. Astro consumes that escape before syntax highlighting, so built `site/dist/index.html:34-35` renders `printf 'hi soma` and the closing quote on separate lines. The README keeps `printf 'hi soma\n' > /tmp/soma-demo/input.txt` on one line. The landing does not reproduce the README checkout flow. Escape the backslash as `\\n` and make the built-copy test assert the complete one-line command.

2. `site/src/content/docs/guides/cli.md:13-15` says every client command auto-starts the daemon. `apps/soma_actor/src/soma_cli_main.erl:193-207` excludes `stop`. A cold packaged `soma stop --socket <missing>` exits 1 with `{badmatch,{error,enoent}}` and creates no socket. The guide publishes behavior the command does not provide. Name the actual auto-start verbs or exclude `stop`, then pin that generated copy.

## Questions

None.

## Nits

None.

## Functional evidence

`bash site/test/current-product-surface.sh` rebuilt the production site and printed 25 PASS lines, but direct inspection of the generated landing found the criterion 5 escape bug above. `rebar3 eunit` passed 387 tests, Common Test passed 425 tests, and `rebar3 release` assembled executable `bin/soma` and `bin/somad` entries. Astro preview returned HTTP 200 for all six reviewed routes.

- Criterion 1 — pass: - [x] The built landing product copy names the release's packaged `bin/soma` command as the public entry point. — `test_landing_names_packaged_bin_soma_entry_point` matched the statement in `site/dist/index.html` (SHA-256 `4cbb942f544f7c0d868f7fbbd860d0a56019fee239199a5e67e7622ab7893fc9`), and `/` returned HTTP 200.
- Criterion 2 — pass: - [x] The built landing product copy presents Soma Lisp `.lisp` task files as deterministic `soma run` input. — `test_landing_presents_lisp_task_files_as_run_input` matched `.lisp`, deterministic `soma run`, and `(task ...)` in the same built landing artifact.
- Criterion 3 — pass: - [x] The built landing product copy presents boot auto-resume as shipped behavior for interrupted durable runs. — `test_landing_marks_boot_auto_resume_shipped` matched the shipped safe-resume statement and the non-idempotent-state fail-safe in the built landing.
- Criterion 4 — pass: - [x] The built landing product copy presents config-registered CLI tools as a shipped extension path. — `test_landing_marks_config_registered_cli_tools_shipped` matched the shipped `(tool ...)` and `~/.soma/tools/` extension-path statement in the built landing.
- Criterion 5 — fail: - [x] The built landing quick start reproduces the README checkout flow from `rebar3 release` through `_build/default/rel/somad/bin/soma` to `soma trace` with a `.lisp` `(task ...)` source. — `test_landing_quick_start_matches_readme_checkout_flow` found its six coarse fragments, but `site/dist/index.html:34-35` splits the README's one-line `printf 'hi soma\n'` command into two rendered lines because the Astro template consumes `\n`.
- Criterion 6 — pass: - [x] The built landing quick start labels deterministic `soma run` as model-free. — `test_landing_labels_run_model_free` matched `Deterministic soma run is model-free.` in the built landing.
- Criterion 7 — pass: - [x] The built Quick Start page uses the README's `.lisp` pipeline filename. — `test_quick_start_uses_pipeline_lisp` found both `pipeline.lisp` commands, rejected `/tmp/soma-demo/pipeline.lfe`, and `/start/quick-start/` returned HTTP 200 with SHA-256 `f729036ce77ce4f93047b4248ef209dbf83b7969405014e11c0616adcfca6c18`.
- Criterion 8 — pass: - [x] The built Tools page describes `soma_tool_registry:catalog/0` as the model-facing `description`/`params` surface. — `test_tools_documents_model_facing_catalog` matched the exact catalog projection in `site/dist/concepts/tools/index.html` (SHA-256 `edf3bbb1890b8ea62d42f45bef8b707b420d2152d246c8879e7f65a5677b3e98`), and `/concepts/tools/` returned HTTP 200.
- Criterion 9 — pass: - [x] The built Tools page traces `~/.soma/tools/*.lisp` manifests through `soma_tool_manifest:normalize/1` into the registry. — `test_tools_documents_config_manifest_registration_path` found those three path fragments in order in the built Tools page.
- Criterion 10 — pass: - [x] The built Tools page explains whole-argument `argv` placeholders for declared params. — `test_tools_documents_whole_argument_placeholders` matched complete-element replacement, the declared-param requirement, and the no-substring rule in the built Tools page.
- Criterion 11 — pass: - [x] The built Tools page lists `state`/`false`/30000 ms as the omitted config-tool defaults. — `test_tools_documents_config_tool_defaults` matched all three defaults in one generated paragraph.
- Criterion 12 — pass: - [x] The built Tools page presents `ask_actor` as an actor-owned registered tool. — `test_tools_documents_actor_owned_ask_actor` matched actor ownership and boot registration in the built Tools page.
- Criterion 13 — pass: - [x] The built CLI guide traces `soma tool register <file>` from immediate live registration to normalized persistence under `~/.soma/tools/` to boot reload. — `test_cli_documents_live_register_persist_reload` found persistence, live registration, rollback guarantees, and boot reload in `site/dist/guides/cli/index.html` (SHA-256 `d43270413a8076acb6e687415c4a7b2e00733ee17c85d3e161a9816dc3e00dae`); EUnit's `test_packaged_tool_verbs_autostart_daemon` proved the cold packaged register path.
- Criterion 14 — pass: - [x] The built CLI guide lists `name`/`effect`/`idempotent`/`adapter`/optional `description` as the `soma tool list` output. — `test_cli_documents_tool_list_fields` matched all five documented fields in the built CLI guide, and `/guides/cli/` returned HTTP 200.
- Criterion 15 — pass: - [x] The built CLI guide traces `soma tool remove <name>` from immediate live removal to owned-file deletion to post-restart absence. — `test_cli_documents_live_remove_delete_restart` found owned-file deletion, live removal, rollback guarantees, and post-restart absence; EUnit's packaged-path test boot-reloaded and removed the persisted tool.
- Criterion 16 — pass: - [x] The built CLI guide identifies built-in-name protection as a tool-management invariant. — `test_cli_documents_builtin_name_protection` matched the protected-name invariant in the built CLI guide.
- Criterion 17 — pass: - [x] The built Decision Layer page describes `[llm] plan = true` as the shipped OpenAI-compatible path to gated `(run-steps ...)` execution. — `test_decision_layer_documents_configured_planning_path` found configuration, compilation, proposal normalization, policy, budget, and actor-owned execution in `site/dist/concepts/decision-layer/index.html` (SHA-256 `3c5f23b920fb9f0f4583c26c8b9dfdc50517bc9c3390babe08b84f8cde1cf838`), and `/concepts/decision-layer/` returned HTTP 200.
- Criterion 18 — pass: - [x] The built Decision Layer page identifies fixed provider responses as the network-free planning gate. — `test_decision_layer_documents_fixed_response_gate` matched the fixed-response and no-socket statement in the built Decision Layer page.
- Criterion 19 — pass: - [x] The built Decision Layer page locates `SOMA_LLM_API_KEY` in the daemon environment. — `test_decision_layer_places_api_key_in_daemon_environment` matched the daemon-starting environment statement in the built Decision Layer page.
- Criterion 20 — pass: - [x] The built Roadmap marks the CLI/config structured-planning surface as shipped. — `test_roadmap_marks_cli_config_planning_shipped` matched the completed provider, actor-planning, and CLI/config-planning entry in `site/dist/reference/roadmap/index.html` (SHA-256 `d57ffbac58058f966a6a0d154a0ae5abfea73a1b463fcd93ae46f12fc256b68b`), and `/reference/roadmap/` returned HTTP 200.
- Criterion 21 — pass: - [x] The built Roadmap records the shipped tools track from manifest v2 through `ask_actor`. — `test_roadmap_marks_tool_track_shipped` matched manifest v2, `catalog/0`, config tools, the planning prompt, and `ask_actor`; `test_roadmap_keeps_unshipped_tool_slices_open` kept T.3 deferred and T.5 future.
- Criterion 22 — pass: - [x] The built Roadmap records live config-tool management as shipped. — `test_roadmap_marks_live_tool_management_shipped` matched the completed `register` / `list` / `remove` entry, and `test_roadmap_labels_completed_tracks` rejected the old `building now` heading.
