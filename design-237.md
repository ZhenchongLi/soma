# [cc] site: refresh the public product surface to current Soma capabilities

## Current state

The English site builds from Astro and Starlight sources under `site/src/`.
The standalone landing page is `site/src/pages/index.astro`. The five docs
surfaces in this issue are Markdown pages under `site/src/content/docs/`.
Existing site checks run `npm ci && npm run build`, then inspect generated HTML
under `site/dist/`.

The site still describes an older product snapshot:

- The landing keeps the OTP thesis and current dark layout, but its product
  cards stop at the compile-only DSL, the generic decision layer, and resume
  reconstruction. Its quick-start string runs `pipeline.lfe` with a bare
  `soma` command. It does not show the checkout release path, a `(task ...)`
  `.lisp` file, or the trace command from the README flow.
- The Quick Start page already follows most of the README example, but it names
  the task `pipeline.lfe`. The README names it `pipeline.lisp` and calls that
  file the public `soma run` input.
- The Tools page stops at the v0.2 manifest and adapter contract. It omits the
  model-facing catalog, config tool loading, typed argv placeholders, safe
  defaults, and the actor-owned `ask_actor` tool.
- The CLI guide documents the packaged command and daemon, but it has no live
  tool-management guide. It also says structured real-provider proposals are
  future work, which now contradicts the shipped planning path.
- The Decision Layer page names the OpenAI-compatible provider seam, but it does
  not connect `[llm] plan = true` to Lisp planning, the normal gates, or owned
  run execution.
- The Roadmap still labels the CLI/config planning surface as next work. It has
  no tools track and no record of live config-tool management.

The shipped code and the root README provide the facts the site must present.
`rebar.config` overlays `scripts/soma` as the release's `bin/soma` task command.
`soma_app` calls `soma_run_auto_resume` after durable runtime boot.
`soma_tool_config:load_dir/1` reads `~/.soma/tools/*.lisp`, compiles each form,
and sends the manifest through `soma_tool_registry:register_tool/1` and
`soma_tool_manifest:normalize/1`. The registry exposes the model-facing
`catalog/0` projection. `soma_run` replaces a whole argv element such as
`"{path}"` from its declared param. `soma_actor_app` registers
`soma_tool_ask_actor` at actor application boot.

Live tool management is also present. `soma_cli_main` dispatches `tool register`,
`tool list`, and `tool remove`. `soma_cli_server` validates before changing
state. It persists successful registrations under the configured tools
directory, reloads them through the boot loader, and removes the owned file
before unregistering a config tool. Built-in names are protected at both
registration and removal boundaries. Planning mode carries `plan => true` from
`soma_config`, reads fixed provider responses without a network socket in the
gate, compiles `(run-steps ...)`, and sends approved work through normalization,
policy, budgets, and the supervised run path.

## Approach

Keep the existing routes, Astro/Starlight setup, page structure, CSS classes,
metadata, fonts, artwork, GitHub links, and Soma red styling. Change only the
copy sources named by the issue. Add one site test harness for the new built
copy contract.

Update `site/src/pages/index.astro` in two places. Refresh the product copy so it
calls the packaged release `bin/soma` command the public entry point. Present
Soma Lisp `.lisp` task files as deterministic `soma run` input that needs no
model. Mark boot auto-resume for interrupted durable runs as shipped. Present
config-registered CLI tools under `~/.soma/tools/` as a shipped extension path.
Keep the supervision thesis as the lead and keep open work out of the shipped
feature copy.

Replace the landing's `quickStart` string with the README checkout flow. It
starts with `rebar3 release` and binds
`SOMA="_build/default/rel/somad/bin/soma"`. It writes
`/tmp/soma-demo/pipeline.lisp` as a `(task ...)` form, runs that file, and ends
with `$SOMA trace "<correlation-id-from-result>"`. Add a short sentence beside
the block that calls deterministic `soma run` model-free. The existing code
component and quick-start section stay in place.

Change `site/src/content/docs/start/quick-start.md` only where its example
filename differs from the README. Both the heredoc target and the `$SOMA run`
argument become `/tmp/soma-demo/pipeline.lisp`. Keep the current model-free
explanation.

Expand `site/src/content/docs/concepts/tools.md` from the adapter-only snapshot
to the current tool surface. Explain that `soma_tool_registry:catalog/0`
contains only each described tool's model-facing `name`, `description`, and
`params`. Trace config files from `~/.soma/tools/*.lisp` through the Lisp reader,
`soma_tool_config`, `soma_tool_manifest:normalize/1`, and the live registry.
Describe a placeholder such as `"{path}"` as one complete argv element. State
that its name must exist in declared `params`. State that Soma does not perform
substring interpolation. List omitted config-tool defaults as `state`, `false`,
and 30000 ms. Add `ask_actor` as an `erlang_module` tool owned and registered by
the actor application.

Add a tool-management section to
`site/src/content/docs/guides/cli.md`. The register flow must say that
`soma tool register <file>` validates once, becomes live immediately, writes a
normalized `<name>.lisp` under `~/.soma/tools/`, and returns after the persisted
form is ready for boot reload. The list flow must name `name`, `effect`,
`idempotent`, and `adapter`. It must say `description` is included only when
present. The remove flow must say that `soma tool remove <name>` removes the live
config tool, deletes only its owned file, and leaves the name absent after
restart. State the common invariant once: built-ins cannot be replaced,
removed, or have their safety metadata changed by config tools. Update the
guide's status and command inventory so these commands do not sit beside stale
claims that they are unavailable.

Add a configured-planning section to
`site/src/content/docs/concepts/decision-layer.md`. Show the shipped
OpenAI-compatible `[llm]` config with `plan = true`. Trace provider text as a
Soma Lisp `(run-steps ...)` proposal through compilation, proposal
normalization, the name allowlist, budgets, and the actor-owned supervised run.
Explain that gate tests supply fixed provider responses and open no network
socket. State that `SOMA_LLM_API_KEY` belongs in the environment that starts the
daemon. Do not imply that the key belongs in TOML or a task file.

Bring `site/src/content/docs/reference/roadmap.md` forward only for the shipped
tracks named by this issue. Mark actor planning plus the CLI/config planning
surface done. Add a tools track that records manifest v2 and `catalog/0`, config
tools, the catalog-fed planning prompt, and `ask_actor` as done. Record live
`register` / `list` / `remove` management as done. Remove contradictory lines
that call structured planning future work. Keep effect-aware policy, a human
ask path, memory, MCP, DAG execution, compaction, and Linux artifacts visibly
open or deferred.

Add `site/test/current-product-surface.sh`. It resolves `site/` from the script
location and runs `npm ci && npm run build` once. It checks all six expected
HTML files exist. A small shell or Perl helper converts each generated HTML file
to normalized visible text by removing tags, decoding the common entities used
by these pages, and collapsing whitespace. Named test functions then use fixed
fragments and ordered-fragment checks. This keeps assertions on production
output while avoiding failures caused only by inline `<code>` markup. The
harness adds no package dependency.

## Acceptance criteria → tests

### Criterion 1 — landing names the packaged public command
- Call chain: `npm run build` → Astro compiles `site/src/pages/index.astro` → `site/dist/index.html`
- Test entry: `npm run build` with no layer skipped, followed by a normalized-text assertion over `site/dist/index.html`
- Code boundary: `site/src/pages/index.astro` and the landing assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the landing product copy owns the statement that the release's packaged `bin/soma` is Soma's public entry point
- Test: `test_landing_names_packaged_bin_soma_entry_point` in `site/test/current-product-surface.sh`

### Criterion 2 — landing presents deterministic Lisp task input
- Call chain: `npm run build` → Astro compiles `site/src/pages/index.astro` → `site/dist/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an assertion that joins `.lisp`, `soma run`, deterministic task input, and the `(task ...)` form on the landing
- Code boundary: `site/src/pages/index.astro` and the landing assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the landing product copy owns the public task-file and deterministic-run positioning
- Test: `test_landing_presents_lisp_task_files_as_run_input` in `site/test/current-product-surface.sh`

### Criterion 3 — landing marks boot auto-resume shipped
- Call chain: `npm run build` → Astro compiles `site/src/pages/index.astro` → `site/dist/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an assertion that the landing calls boot auto-resume shipped behavior for interrupted durable runs
- Code boundary: `site/src/pages/index.astro` and the landing assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the landing resume feature copy owns the shipped boot behavior
- Test: `test_landing_marks_boot_auto_resume_shipped` in `site/test/current-product-surface.sh`

### Criterion 4 — landing marks config CLI tools shipped
- Call chain: `npm run build` → Astro compiles `site/src/pages/index.astro` → `site/dist/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an assertion over config-registered CLI tools and `~/.soma/tools/`
- Code boundary: `site/src/pages/index.astro` and the landing assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the landing extension-path copy owns the shipped config-tool claim
- Test: `test_landing_marks_config_registered_cli_tools_shipped` in `site/test/current-product-surface.sh`

### Criterion 5 — landing quick start matches the README checkout flow
- Call chain: `npm run build` → Astro renders the landing `quickStart` code component → `site/dist/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an ordered check for `rebar3 release`, `_build/default/rel/somad/bin/soma`, `pipeline.lisp`, `(task`, `$SOMA run`, and `$SOMA trace`
- Code boundary: the `quickStart` string in `site/src/pages/index.astro` and the landing assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the landing quick-start block owns the checkout-to-trace command sequence
- Test: `test_landing_quick_start_matches_readme_checkout_flow` in `site/test/current-product-surface.sh`

### Criterion 6 — landing labels deterministic run model-free
- Call chain: `npm run build` → Astro compiles `site/src/pages/index.astro` → `site/dist/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an assertion that deterministic `soma run` needs no model
- Code boundary: `site/src/pages/index.astro` and the landing assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the landing quick-start explanation owns the model-free label
- Test: `test_landing_labels_run_model_free` in `site/test/current-product-surface.sh`

### Criterion 7 — Quick Start uses `pipeline.lisp`
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/start/quick-start.md` → `site/dist/start/quick-start/index.html`
- Test entry: `npm run build` with no layer skipped, followed by checks for the `.lisp` heredoc target and `$SOMA run` argument and against the old `/tmp/soma-demo/pipeline.lfe` path
- Code boundary: `site/src/content/docs/start/quick-start.md` and the Quick Start assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Quick Start page owns its public example filename
- Test: `test_quick_start_uses_pipeline_lisp` in `site/test/current-product-surface.sh`

### Criterion 8 — Tools documents the model-facing catalog
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/tools.md` → `site/dist/concepts/tools/index.html`
- Test entry: `npm run build` with no layer skipped, followed by checks that connect `soma_tool_registry:catalog/0` to the model-facing `description` and `params` fields
- Code boundary: `site/src/content/docs/concepts/tools.md` and the Tools assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Tools concept page owns the registry catalog contract presented to site readers
- Test: `test_tools_documents_model_facing_catalog` in `site/test/current-product-surface.sh`

### Criterion 9 — Tools traces config manifests into the registry
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/tools.md` → `site/dist/concepts/tools/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an ordered check for `~/.soma/tools/*.lisp`, `soma_tool_manifest:normalize/1`, and the registry
- Code boundary: `site/src/content/docs/concepts/tools.md` and the Tools assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Tools concept page owns the config-manifest registration path
- Test: `test_tools_documents_config_manifest_registration_path` in `site/test/current-product-surface.sh`

### Criterion 10 — Tools explains whole-argument placeholders
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/tools.md` → `site/dist/concepts/tools/index.html`
- Test entry: `npm run build` with no layer skipped, followed by checks for a `"{param}"` example, a declared `params` requirement, whole argv replacement, and no substring interpolation
- Code boundary: `site/src/content/docs/concepts/tools.md` and the Tools assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Tools concept page owns the CLI argv placeholder rule
- Test: `test_tools_documents_whole_argument_placeholders` in `site/test/current-product-surface.sh`

### Criterion 11 — Tools lists conservative omitted defaults
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/tools.md` → `site/dist/concepts/tools/index.html`
- Test entry: `npm run build` with no layer skipped, followed by one defaults assertion containing omitted metadata, `state`, `false`, and 30000 ms
- Code boundary: `site/src/content/docs/concepts/tools.md` and the Tools assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Tools concept page owns the config-tool safety-default explanation
- Test: `test_tools_documents_config_tool_defaults` in `site/test/current-product-surface.sh`

### Criterion 12 — Tools presents actor-owned `ask_actor`
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/tools.md` → `site/dist/concepts/tools/index.html`
- Test entry: `npm run build` with no layer skipped, followed by checks that call `ask_actor` actor-owned and registered at actor application boot
- Code boundary: `site/src/content/docs/concepts/tools.md` and the Tools assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Tools concept page owns the capability-app registration description for `ask_actor`
- Test: `test_tools_documents_actor_owned_ask_actor` in `site/test/current-product-surface.sh`

### Criterion 13 — CLI traces live registration to boot reload
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/guides/cli.md` → `site/dist/guides/cli/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an ordered check from `soma tool register <file>` to immediate live registration, normalized persistence under `~/.soma/tools/`, and boot reload
- Code boundary: `site/src/content/docs/guides/cli.md` and the CLI assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the CLI guide owns the operator-visible register lifecycle
- Test: `test_cli_documents_live_register_persist_reload` in `site/test/current-product-surface.sh`

### Criterion 14 — CLI lists the tool summary fields
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/guides/cli.md` → `site/dist/guides/cli/index.html`
- Test entry: `npm run build` with no layer skipped, followed by one `soma tool list` assertion naming `name`, `effect`, `idempotent`, `adapter`, and optional `description`
- Code boundary: `site/src/content/docs/guides/cli.md` and the CLI assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the CLI guide owns the documented tool-list projection
- Test: `test_cli_documents_tool_list_fields` in `site/test/current-product-surface.sh`

### Criterion 15 — CLI traces removal through restart
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/guides/cli.md` → `site/dist/guides/cli/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an ordered check from `soma tool remove <name>` to live removal, owned-file deletion, and post-restart absence
- Code boundary: `site/src/content/docs/guides/cli.md` and the CLI assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the CLI guide owns the operator-visible remove lifecycle
- Test: `test_cli_documents_live_remove_delete_restart` in `site/test/current-product-surface.sh`

### Criterion 16 — CLI states built-in-name protection
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/guides/cli.md` → `site/dist/guides/cli/index.html`
- Test entry: `npm run build` with no layer skipped, followed by a tool-management invariant assertion that built-ins cannot be replaced or removed
- Code boundary: `site/src/content/docs/guides/cli.md` and the CLI assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the CLI guide owns the documented built-in protection invariant
- Test: `test_cli_documents_builtin_name_protection` in `site/test/current-product-surface.sh`

### Criterion 17 — Decision Layer documents configured gated planning
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/decision-layer.md` → `site/dist/concepts/decision-layer/index.html`
- Test entry: `npm run build` with no layer skipped, followed by an ordered check from OpenAI-compatible `[llm] plan = true` through `(run-steps ...)`, policy and budget gates, and supervised execution
- Code boundary: `site/src/content/docs/concepts/decision-layer.md` and the Decision Layer assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Decision Layer page owns the configured real-provider planning path
- Test: `test_decision_layer_documents_configured_planning_path` in `site/test/current-product-surface.sh`

### Criterion 18 — Decision Layer names the network-free planning gate
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/decision-layer.md` → `site/dist/concepts/decision-layer/index.html`
- Test entry: `npm run build` with no layer skipped, followed by one assertion that fixed provider responses keep planning gate tests network-free
- Code boundary: `site/src/content/docs/concepts/decision-layer.md` and the Decision Layer assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Decision Layer page owns the gate-versus-live-provider distinction
- Test: `test_decision_layer_documents_fixed_response_gate` in `site/test/current-product-surface.sh`

### Criterion 19 — Decision Layer locates the API key
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/concepts/decision-layer.md` → `site/dist/concepts/decision-layer/index.html`
- Test entry: `npm run build` with no layer skipped, followed by one assertion that `SOMA_LLM_API_KEY` belongs in the daemon-starting environment
- Code boundary: `site/src/content/docs/concepts/decision-layer.md` and the Decision Layer assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Decision Layer page owns the provider-secret placement guidance
- Test: `test_decision_layer_places_api_key_in_daemon_environment` in `site/test/current-product-surface.sh`

### Criterion 20 — Roadmap marks CLI/config planning shipped
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/reference/roadmap.md` → `site/dist/reference/roadmap/index.html`
- Test entry: `npm run build` with no layer skipped, followed by a shipped-status assertion joining structured planning with the CLI/config surface
- Code boundary: `site/src/content/docs/reference/roadmap.md` and the Roadmap assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Roadmap page owns the completion state of the node B product surface
- Test: `test_roadmap_marks_cli_config_planning_shipped` in `site/test/current-product-surface.sh`

### Criterion 21 — Roadmap records the shipped tools track
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/reference/roadmap.md` → `site/dist/reference/roadmap/index.html`
- Test entry: `npm run build` with no layer skipped, followed by checks that mark manifest v2, `catalog/0`, config tools, the planning prompt, and `ask_actor` done
- Code boundary: `site/src/content/docs/reference/roadmap.md` and the Roadmap assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Roadmap page owns the status sequence from T.1 through the shipped T.4 capability
- Test: `test_roadmap_marks_tool_track_shipped` in `site/test/current-product-surface.sh`

### Criterion 22 — Roadmap records live config-tool management shipped
- Call chain: `npm run build` → Starlight renders `site/src/content/docs/reference/roadmap.md` → `site/dist/reference/roadmap/index.html`
- Test entry: `npm run build` with no layer skipped, followed by a done-status assertion that groups live `soma tool register`, `list`, and `remove`
- Code boundary: `site/src/content/docs/reference/roadmap.md` and the Roadmap assertions in `site/test/current-product-surface.sh`
- Responsibility owner: the Roadmap page owns the completion state of live config-tool management
- Test: `test_roadmap_marks_live_tool_management_shipped` in `site/test/current-product-surface.sh`

## Risks & trade-offs

- The landing quick start becomes much taller than the current four-line block.
  The existing code container already scrolls horizontally and the issue asks
  for the README flow, so keeping the complete flow is more important than
  preserving the old block height.
- Built-copy checks are intentionally sensitive to product wording. Normalizing
  generated HTML removes markup noise, but a later copy edit can still require a
  test update. That is useful here because the issue is about preventing the
  public surface from drifting back to an older status.
- One harness builds once for all 22 assertions. This keeps the site check much
  faster than 22 clean installs. A build failure stops the copy assertions, so
  the harness must print the build log and the missing route before it exits.
- The Quick Start example is duplicated between the README, landing, and docs
  page. This issue does not introduce a shared content system. The ordered build
  assertions lock the current public sequence, but a future README change still
  needs a deliberate site update.
- The Roadmap refresh can overstate work if done and open items are mixed in one
  summary. Keep shipped planning and tool management separate from effect-aware
  policy, human asks, memory, MCP, DAG execution, compaction, and Linux release
  artifacts.
- The issue does not request visual regression tooling. Production edits stay
  inside existing content containers, and the current route, CSS, font, accent,
  metadata, and link harnesses remain the regression guard for the unchanged
  visual surface.
