### Claude

## Verdict

changes-requested

## Real issues

1. `site/src/pages/index.astro:107-108` promises that every interrupted durable run resumes automatically. That is false for a non-idempotent in-flight `state` step. Boot appends `run.failed` with `{resume_unsafe, StepId}` and starts no run. The landing promises continuation where Soma deliberately stops. State that safe runs resume and unsafe runs fail clearly. Change `site/test/current-product-surface.sh:92-104` so it stops enforcing the false promise.

2. `site/src/content/docs/guides/cli.md:105-115` reverses both durability transactions. Register writes first and registers second in `soma_cli_server.erl:227-250`. Remove deletes first and unregisters second in `soma_cli_server.erl:370-388`. A write or delete error leaves the live registry unchanged. The current copy tells operators the wrong failure state and erases the no-live-only and no-resurrection guarantees. Rewrite both flows and the ordered checks at `site/test/current-product-surface.sh:254-301`.

3. `site/src/content/docs/guides/cli.md:6-16,89-101` still omits `soma tool register`, `soma tool list`, and `soma tool remove` from the status summary and command inventory. `design-237.md` requires both updates. A reader scanning the advertised wrapper verbs or the `Commands` table cannot discover the shipped tool-management surface. Add the verbs and cover that inventory in the built-copy test.

## Questions

None.

## Nits

None.

## Functional evidence

`site/test/current-product-surface.sh` built the production site and printed 22 PASS lines. Astro preview served all six target routes with HTTP 200, and every response matched its generated HTML SHA-256 below. `rebar3 eunit --module=soma_lfe_task_doc_tests` passed 40 tests.

- Criterion 1 — pass: - [x] The built landing product copy names the release's packaged `bin/soma` command as the public entry point. — `site/dist/index.html` contained the exact sentence under `test_landing_names_packaged_bin_soma_entry_point`; `/` returned HTTP 200 with SHA-256 `5bec7dddca90acbcf20d14cb3b1aa1f7646c6ed8c6f9cc49740f2f941a099662`.
- Criterion 2 — pass: - [x] The built landing product copy presents Soma Lisp `.lisp` task files as deterministic `soma run` input. — `site/dist/index.html` contained the full `.lisp` / `soma run` / `(task ...)` sentence under `test_landing_presents_lisp_task_files_as_run_input`; the served artifact hash was `5bec7dddca90acbcf20d14cb3b1aa1f7646c6ed8c6f9cc49740f2f941a099662`.
- Criterion 3 — fail: - [x] The built landing product copy presents boot auto-resume as shipped behavior for interrupted durable runs. — `test_landing_marks_boot_auto_resume_shipped` found the built sentence, but that sentence says every interrupted run resumes. `docs/contracts/v0.7-test-contract.md:165` proves unsafe in-flight state steps fail with `{resume_unsafe, StepId}` instead.
- Criterion 4 — pass: - [x] The built landing product copy presents config-registered CLI tools as a shipped extension path. — `site/dist/index.html` contained the shipped `~/.soma/tools/` extension-path sentence under `test_landing_marks_config_registered_cli_tools_shipped`; the served artifact hash was `5bec7dddca90acbcf20d14cb3b1aa1f7646c6ed8c6f9cc49740f2f941a099662`.
- Criterion 5 — pass: - [x] The built landing quick start reproduces the README checkout flow from `rebar3 release` through `_build/default/rel/somad/bin/soma` to `soma trace` with a `.lisp` `(task ...)` source. — `test_landing_quick_start_matches_readme_checkout_flow` found those six ordered fragments in `site/dist/index.html`; the served artifact hash was `5bec7dddca90acbcf20d14cb3b1aa1f7646c6ed8c6f9cc49740f2f941a099662`.
- Criterion 6 — pass: - [x] The built landing quick start labels deterministic `soma run` as model-free. — `test_landing_labels_run_model_free` found `Deterministic soma run is model-free.` in `site/dist/index.html`; `/` returned HTTP 200.
- Criterion 7 — pass: - [x] The built Quick Start page uses the README's `.lisp` pipeline filename. — `test_quick_start_uses_pipeline_lisp` found both `pipeline.lisp` commands and rejected the old `.lfe` path in `site/dist/start/quick-start/index.html`; the page returned HTTP 200 with SHA-256 `f729036ce77ce4f93047b4248ef209dbf83b7969405014e11c0616adcfca6c18`.
- Criterion 8 — pass: - [x] The built Tools page describes `soma_tool_registry:catalog/0` as the model-facing `description`/`params` surface. — `test_tools_documents_model_facing_catalog` found the exact catalog projection in `site/dist/concepts/tools/index.html`; the page returned HTTP 200 with SHA-256 `edf3bbb1890b8ea62d42f45bef8b707b420d2152d246c8879e7f65a5677b3e98`.
- Criterion 9 — pass: - [x] The built Tools page traces `~/.soma/tools/*.lisp` manifests through `soma_tool_manifest:normalize/1` into the registry. — `test_tools_documents_config_manifest_registration_path` found the three fragments in order in `site/dist/concepts/tools/index.html`; the served artifact hash was `edf3bbb1890b8ea62d42f45bef8b707b420d2152d246c8879e7f65a5677b3e98`.
- Criterion 10 — pass: - [x] The built Tools page explains whole-argument `argv` placeholders for declared params. — `test_tools_documents_whole_argument_placeholders` found the full-element replacement and no-substring-interpolation rule in `site/dist/concepts/tools/index.html`.
- Criterion 11 — pass: - [x] The built Tools page lists `state`/`false`/30000 ms as the omitted config-tool defaults. — `test_tools_documents_config_tool_defaults` found all three defaults in one generated paragraph in `site/dist/concepts/tools/index.html`.
- Criterion 12 — pass: - [x] The built Tools page presents `ask_actor` as an actor-owned registered tool. — `test_tools_documents_actor_owned_ask_actor` found the actor-owned, actor-app boot-registration sentence in `site/dist/concepts/tools/index.html`.
- Criterion 13 — fail: - [x] The built CLI guide traces `soma tool register <file>` from immediate live registration to normalized persistence under `~/.soma/tools/` to boot reload. — `site/dist/guides/cli/index.html` returned HTTP 200 with SHA-256 `fb89b45cb01be185fd8930becd140ae7f272174f6832cd948304222f5c6dfc35`, but its generated text puts live registration before persistence. `soma_cli_server.erl:227-250` persists first so a write failure leaves no live-only tool.
- Criterion 14 — pass: - [x] The built CLI guide lists `name`/`effect`/`idempotent`/`adapter`/optional `description` as the `soma tool list` output. — `test_cli_documents_tool_list_fields` found the exact five-field sentence in `site/dist/guides/cli/index.html`; the served artifact hash was `fb89b45cb01be185fd8930becd140ae7f272174f6832cd948304222f5c6dfc35`.
- Criterion 15 — fail: - [x] The built CLI guide traces `soma tool remove <name>` from immediate live removal to owned-file deletion to post-restart absence. — `test_cli_documents_live_remove_delete_restart` found that sequence in the generated page, but `soma_cli_server.erl:370-388` deletes the owned file before live removal. A delete failure keeps the tool live to prevent restart resurrection.
- Criterion 16 — pass: - [x] The built CLI guide identifies built-in-name protection as a tool-management invariant. — `test_cli_documents_builtin_name_protection` found the protected-name invariant in `site/dist/guides/cli/index.html`.
- Criterion 17 — pass: - [x] The built Decision Layer page describes `[llm] plan = true` as the shipped OpenAI-compatible path to gated `(run-steps ...)` execution. — `test_decision_layer_documents_configured_planning_path` found all eight ordered path fragments in `site/dist/concepts/decision-layer/index.html`; the page returned HTTP 200 with SHA-256 `3c5f23b920fb9f0f4583c26c8b9dfdc50517bc9c3390babe08b84f8cde1cf838`.
- Criterion 18 — pass: - [x] The built Decision Layer page identifies fixed provider responses as the network-free planning gate. — `test_decision_layer_documents_fixed_response_gate` found the fixed-response/no-socket sentence in `site/dist/concepts/decision-layer/index.html`.
- Criterion 19 — pass: - [x] The built Decision Layer page locates `SOMA_LLM_API_KEY` in the daemon environment. — `test_decision_layer_places_api_key_in_daemon_environment` found the exact environment sentence in `site/dist/concepts/decision-layer/index.html`.
- Criterion 20 — pass: - [x] The built Roadmap marks the CLI/config structured-planning surface as shipped. — `test_roadmap_marks_cli_config_planning_shipped` found the `[done — provider + actor planning + CLI/config planning surface]` entry in `site/dist/reference/roadmap/index.html`; the page returned HTTP 200 with SHA-256 `76b4fb33c50f5531b3ee24ea7e8d7239af8831658479e43ada1bdb6e538ed239`.
- Criterion 21 — pass: - [x] The built Roadmap records the shipped tools track from manifest v2 through `ask_actor`. — `test_roadmap_marks_tool_track_shipped` found manifest v2, `catalog/0`, config tools, the catalog-fed prompt, and `ask_actor` in the generated Roadmap.
- Criterion 22 — pass: - [x] The built Roadmap records live config-tool management as shipped. — `test_roadmap_marks_live_tool_management_shipped` found the `[done]` `register` / `list` / `remove` entry in `site/dist/reference/roadmap/index.html`.
