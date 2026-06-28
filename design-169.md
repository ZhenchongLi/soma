# site: docs — Concepts pages (English)

## Current state

The Soma site lives under `site/` — Astro 5 with Starlight 0.34, English-only,
directory-format output so every route lands as `<route>/index.html`. What is
merged today:

- `site/astro.config.mjs` — Starlight is configured with a title and custom CSS,
  but **no `sidebar` key**. Starlight auto-generates the sidebar from the file
  tree right now.
- `site/src/content/docs/start/overview.md` — the one real docs page (route
  `start/overview/`). There is no `start/quick-start.md`.
- `site/src/pages/index.astro` — the hand-built landing page (route `/`).
- `site/public/` holds six SVGs. The three the architecture page needs are all
  present: `supervision-tree.svg`, `run-states.svg`, `tool-call.svg`. (Also
  `favicon.svg`, `soma-actor-flow.svg`, `soma-actor-loop.svg`.)
- `site/test/` holds the existing per-criterion bash harnesses from earlier
  slices. They follow one shape: resolve `site/` from the script's own location,
  run `npm ci && npm run build`, then assert on `dist/` files or on the captured
  build log. This issue's verifications follow the same shape.

What is missing: the whole Concepts section. There are no pages under
`site/src/content/docs/concepts/`, and the sidebar has no Concepts group, so a
reader has no way to reach this material. The README and the `docs/` sources hold
the content; nothing has been ported into the site yet.

## Approach

Add 8 Markdown pages under `site/src/content/docs/concepts/` and switch the
Starlight sidebar from auto-generated to an explicit `sidebar` array in
`site/astro.config.mjs`. Once `sidebar` is set explicitly, Starlight stops
auto-deriving groups, so the config must list every group the site shows — at
minimum the Concepts group this issue requires. The landing page and the overview
route are untouched by the page additions; the sidebar change only affects the
docs-route chrome, not the landing route.

Each page is `concepts/<slug>.md` with YAML frontmatter (`title` plus a one-line
`description`), content adapted faithfully from the README and the one named
`docs/` source for that page, `##`/`###` headings, and code fences tagged
`erlang` / `bash` / `lisp`. The README is authoritative — pages must not invent
or contradict it. The architecture page embeds the three SVGs by root-absolute
path (`/supervision-tree.svg`, `/run-states.svg`, `/tool-call.svg`); those files
already sit in `site/public/`, so Astro copies them to `dist/` unchanged.

The eight slugs, titles, and sources are fixed by the issue table:
`architecture`, `steps`, `tools`, `actors`, `decision-layer`,
`events-and-trace`, `durability`, `resume`. Each "must mention" string in that
table is the literal token the corresponding acceptance criterion greps for in
the built HTML, so each page must contain its token in rendered prose or a code
fence: `soma_run`, `from_step`, `manifest`, `soma_actor`, `policy`,
`correlation_id`, `disk_log`, `run.started`.

On the sidebar: an explicit `sidebar` with a Concepts group whose eight items
point at the eight `/concepts/<slug>/` routes. Starlight renders each item as an
`<a href="/concepts/<slug>/">` inside a group labeled "Concepts". The sidebar
appears in the chrome of every docs route, so any built docs page (for instance
`concepts/architecture/index.html`) contains the full rendered sidebar — that is
where the sidebar criterion reads it from.

The "no warning lines" criterion is strict: a sidebar link to a page that does
not exist makes Starlight emit a warning line, which fails the build-clean check.
This drives the `quick-start` decision below.

### The quick-start question

The original request's sidebar sketch had a "Start Here" group with both
`start/overview` and `start/quick-start`. Only `start/overview.md` exists. If the
explicit sidebar links `start/quick-start`, Starlight warns about the missing
page and the clean-build criterion fails.

Recommendation: **do not add a Start Here group that links `quick-start`.** The
acceptance criteria require only the Concepts group plus the two existing routes
(`/` and `start/overview/`) still building. The simplest clean build is an
explicit sidebar with the Concepts group alone, leaving `start/overview/` reachable
by its auto behavior is not possible once `sidebar` is explicit — so if Start Here
should stay in the nav, add a Start Here group that lists **only** `start/overview`.
Either way, no sidebar item may point at `quick-start` unless the Dev also creates
`start/quick-start.md`. Creating that page is allowed but not required by any
criterion here.

## Acceptance criteria → tests

These are docs, not Erlang. Every check is a bash harness under `site/test/` that
runs `npm ci && npm run build` once and then asserts on the build log or on files
in `site/dist/`, matching the existing harness shape (`build-clean.sh`,
`build-en-docs.sh`, `build-diagrams.sh`).

### Criterion 1 — build exits clean with no error/warning lines
- Call chain: none (build-output assertion). `npm run build` runs Astro +
  Starlight over the new pages and the explicit sidebar; the harness captures
  combined stdout+stderr.
- Test entry: the captured build log. The harness greps the log for any line
  matching `error|warning` (case-insensitive) and fails if one is found. This is
  the existing `build-clean.sh` pattern, unchanged.
- Test: `build-clean.sh` in `site/test/`

### Criterion 2 — architecture page builds and contains `soma_run`
- Call chain: none (built-file read). Build produces
  `dist/concepts/architecture/index.html`.
- Test entry: that HTML file. Assert it exists, then grep it for `soma_run`.
- Test: `concept-architecture.sh` in `site/test/`

### Criterion 3 — steps page builds and contains `from_step`
- Call chain: none (built-file read).
- Test entry: `dist/concepts/steps/index.html` — assert exists, grep `from_step`.
- Test: `concept-steps.sh` in `site/test/`

### Criterion 4 — tools page builds and contains `manifest`
- Call chain: none (built-file read).
- Test entry: `dist/concepts/tools/index.html` — assert exists, grep `manifest`.
- Test: `concept-tools.sh` in `site/test/`

### Criterion 5 — actors page builds and contains `soma_actor`
- Call chain: none (built-file read).
- Test entry: `dist/concepts/actors/index.html` — assert exists, grep `soma_actor`.
- Test: `concept-actors.sh` in `site/test/`

### Criterion 6 — decision-layer page builds and contains `policy`
- Call chain: none (built-file read).
- Test entry: `dist/concepts/decision-layer/index.html` — assert exists, grep
  `policy`.
- Test: `concept-decision-layer.sh` in `site/test/`

### Criterion 7 — events-and-trace page builds and contains `correlation_id`
- Call chain: none (built-file read).
- Test entry: `dist/concepts/events-and-trace/index.html` — assert exists, grep
  `correlation_id`.
- Test: `concept-events-and-trace.sh` in `site/test/`

### Criterion 8 — durability page builds and contains `disk_log`
- Call chain: none (built-file read).
- Test entry: `dist/concepts/durability/index.html` — assert exists, grep
  `disk_log`.
- Test: `concept-durability.sh` in `site/test/`

### Criterion 9 — resume page builds and contains `run.started`
- Call chain: none (built-file read).
- Test entry: `dist/concepts/resume/index.html` — assert exists, grep
  `run.started`.
- Test: `concept-resume.sh` in `site/test/`

### Criterion 10 — architecture page references the supervision SVG and the file ships
- Call chain: none (built-file read + asset-copy check).
- Test entry: `dist/concepts/architecture/index.html` — grep it for
  `/supervision-tree.svg`. Then assert `dist/supervision-tree.svg` exists (Astro
  copies it from `public/`).
- Test: `concept-architecture-svg.sh` in `site/test/`

### Criterion 11 — sidebar shows a Concepts group with all eight links
- Call chain: none (rendered-HTML read). The sidebar renders into every docs
  route's chrome, so any built concepts page carries the full sidebar.
- Test entry: a built docs page, for instance
  `dist/concepts/architecture/index.html`. Assert the HTML contains an `href`
  for each of the eight routes — `/concepts/architecture/`, `/concepts/steps/`,
  `/concepts/tools/`, `/concepts/actors/`, `/concepts/decision-layer/`,
  `/concepts/events-and-trace/`, `/concepts/durability/`, `/concepts/resume/` —
  and that the literal group label `Concepts` appears.
- Test: `sidebar-concepts.sh` in `site/test/`

### Criterion 12 — landing route still builds
- Call chain: none (built-file read).
- Test entry: `dist/index.html` — assert it exists after the build. (Guards the
  landing route against the sidebar config change.)
- Test: `landing-still-builds.sh` in `site/test/` (or reuse an existing
  landing build harness).

### Criterion 13 — overview route still builds
- Call chain: none (built-file read).
- Test entry: `dist/start/overview/index.html` — assert it exists. This is what
  the existing `build-en-docs.sh` already checks; it doubles as the regression
  guard for the explicit-sidebar change.
- Test: `build-en-docs.sh` in `site/test/`

## Risks & trade-offs

- **Explicit sidebar is all-or-nothing.** Setting `sidebar` turns off Starlight's
  auto-generation for the whole site. After this change the config owns the nav,
  so a page added later with no sidebar entry will silently not appear in the
  nav. That is a maintenance cost the issue accepts in exchange for a stable,
  testable Concepts group.
- **The clean-build criterion is brittle by design.** It fails on any line
  containing `error` or `warning`, including ones from a dependency that have
  nothing to do with this issue. If `npm ci` or a Starlight version prints an
  incidental warning, the criterion fails even though the pages are correct. The
  Dev should run the build locally and confirm a clean log before relying on the
  harness; if a non-Soma warning appears, that is a separate problem from the page
  content.
- **The "must mention" tokens are load-bearing.** Each grep token must survive
  into the rendered HTML. A token only placed in a code fence still renders into
  the HTML, so that is fine — but if a Dev paraphrases and drops the literal token
  (writes "the run process" instead of `soma_run`), the criterion fails even
  though the prose is accurate. Keep the literal token on each page.
- **Dropping `quick-start` from the nav is a real, if minor, gap.** The
  recommendation leaves Start Here with at most one link. A reader loses a
  quick-start entry point until a later slice adds the page. The alternative —
  shipping a `quick-start` link to a missing page — breaks the clean build, so
  this is the safe call for this issue.
