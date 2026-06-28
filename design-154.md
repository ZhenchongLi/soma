# [cc] site: scaffold Astro + Starlight (bilingual, builds clean)

## Current state

The repo has no website. There is no `site/` directory, no npm project, no Node
toolchain checked in. Everything tracked today is the Erlang umbrella (`apps/`,
`rebar.config`, `rebar.lock`) plus prose docs under `docs/`. The merge gate is
`rebar3 eunit && rebar3 ct` and nothing it runs touches a web build.

The five architecture diagrams already exist as committed SVGs under
`docs/diagrams/`: `run-states.svg`, `soma-actor-flow.svg`,
`soma-actor-loop.svg`, `supervision-tree.svg`, `tool-call.svg`. They are not
served anywhere — they only render inside the markdown docs when read on GitHub.

So there is nothing today that produces an HTML site, nothing bilingual, and no
place for the later marketing page or docs port to land. This slice builds that
foundation and nothing more.

## Approach

Add a self-contained npm project under `site/`. It is an Astro project using the
Starlight docs framework. It builds with `npm run build` and is verified by what
that build emits into `site/dist/`. It is never reached by `rebar3 eunit` or
`rebar3 ct`, so the Erlang gate is untouched.

Key decisions:

- **Astro + Starlight, directory-format output.** `astro.config.mjs` sets
  `build.format: 'directory'` so every route lands as `<route>/index.html`. The
  acceptance criteria name paths like `start/overview/index.html`, which is what
  directory format produces. File format would emit `start/overview.html`
  instead and break those checks, so the format is pinned.

- **Bilingual: English at root, 简体中文 under `/zh/`.** Starlight's `locales`
  config sets `root` to `en` and adds a `zh` locale with `lang: 'zh-CN'`.
  English content lives at `src/content/docs/...` and Chinese at
  `src/content/docs/zh/...`. Starlight emits the English routes at `/` and the
  Chinese ones under `/zh/`, sets `<html lang="zh-CN">` on Chinese pages, and
  renders a built-in language picker because more than one locale is configured.

- **Seed docs only.** One docs page per locale at the `start/overview` slug, plus
  the two locale landing pages (Starlight's index/splash). No marketing page, no
  full docs port — those are later slices. The seed pages are enough to prove
  every route and i18n criterion.

- **Design tokens in custom CSS.** A `src/styles/custom.css` overrides
  Starlight's accent custom property to a BEAM/Erlang red hex value (not Elixir
  green) and sets the font stack to Inter for body and IBM Plex Mono for code.
  Fonts ship as self-hosted `@fontsource` packages so the family names appear in
  the built CSS rather than relying on a runtime CDN. The CSS is wired through
  Starlight's `customCss` option so it is bundled into `site/dist/`.

- **Diagrams copied into `public/`.** Astro copies `site/public/` verbatim into
  `site/dist/`. The five SVGs are copied from `docs/diagrams/` into
  `site/public/` (committed copies, not symlinks, so the build is hermetic). The
  favicon rides the same `public/` pipeline.

- **Lockfile committed.** `npm install` runs once during scaffolding and the
  resulting `site/package-lock.json` is committed so `npm ci` is reproducible.
  All of `site/node_modules/` and `site/dist/` stay out of git; a `site/.gitignore`
  ignores them.

- **Nothing changes outside `site/`.** The diagram SVGs are read from
  `docs/diagrams/` and copied in; the originals are not moved or edited. No
  `rebar.config`, no Erlang source, no root `.gitignore` change. The one new
  tracked thing outside `site/` is `design-154.md` from this design step, which
  is not part of the issue's deliverable.

## Acceptance criteria → tests

This is a build-verified npm project, not an Erlang TDD slice. Each criterion is
proven by running the build once and asserting against `site/dist/` output or by
a git/file check. The build command for all build-output checks is
`cd site && npm ci && npm run build`.

### Criterion 1 — clean install and build exits 0
- Call chain: none (build-command exit code)
- Test entry: `cd site && npm ci && npm run build`; assert `$? -eq 0`
- Test: `npm ci && npm run build` exits 0 in `site/`

### Criterion 2 — no error or warning lines in build output
- Call chain: none (build-output text scan)
- Test entry: capture combined stdout+stderr of `npm run build`, grep it
- Test: build log contains no line matching `error` or `warning` (case-insensitive);
  if a benign unavoidable upstream Astro/Starlight warning appears, the relaxed
  form per the issue is "no Soma-caused warning lines" while Criterion 1 still holds

### Criterion 3 — English root route built
- Call chain: none (built-file existence)
- Test entry: stat the file after build
- Test: `site/dist/index.html` exists

### Criterion 4 — Chinese root route built
- Call chain: none (built-file existence)
- Test entry: stat the file after build
- Test: `site/dist/zh/index.html` exists

### Criterion 5 — English seed docs route built
- Call chain: none (built-file existence)
- Test entry: stat the file after build
- Test: `site/dist/start/overview/index.html` exists

### Criterion 6 — Chinese seed docs route built
- Call chain: none (built-file existence)
- Test entry: stat the file after build
- Test: `site/dist/zh/start/overview/index.html` exists

### Criterion 7 — Chinese page carries a zh lang attribute
- Call chain: none (grep against built HTML)
- Test entry: read `site/dist/zh/index.html`
- Test: the file's `<html>` tag has `lang="zh-CN"` (or an equivalent `zh` lang
  value); grep `<html[^>]*lang="zh` against `site/dist/zh/index.html`

### Criterion 8 — English page has a language switcher linking to /zh/
- Call chain: none (grep against built HTML)
- Test entry: read `site/dist/index.html`
- Test: the rendered output contains a language-picker control with an `href`
  into the `/zh/` locale; grep for the Starlight language-select markup plus a
  `/zh/` link in `site/dist/index.html`

### Criterion 9 — built CSS carries the soma red accent token
- Call chain: none (grep against built CSS)
- Test entry: read the bundled CSS under `site/dist/_astro/`
- Test: the built CSS binds a red hex value to Starlight's accent custom
  property; grep the `site/dist/` CSS for `--sl-color-accent` (and its hsl/hue
  inputs) set to the soma red hex

### Criterion 10 — built output references Inter and IBM Plex Mono
- Call chain: none (grep against built output)
- Test entry: read the bundled CSS / built HTML under `site/dist/`
- Test: grep `site/dist/` for both `Inter` and `IBM Plex Mono` font-family names

### Criterion 11 — five architecture SVGs present in public/ and dist/
- Call chain: none (file existence, two locations)
- Test entry: stat each SVG before and after build
- Test: each of `run-states.svg`, `soma-actor-flow.svg`, `soma-actor-loop.svg`,
  `supervision-tree.svg`, `tool-call.svg` exists under `site/public/` and, after
  build, under `site/dist/`

### Criterion 12 — package-lock.json is tracked
- Call chain: none (git index check)
- Test entry: `git ls-files`
- Test: `git ls-files site/package-lock.json` returns that path

### Criterion 13 — no tracked file outside site/ added or modified
- Call chain: none (git diff against the branch base)
- Test entry: `git diff --name-only origin/main...HEAD`
- Test: every changed path is under `site/` (with `design-154.md` from this
  design step the only allowed exception, since it is not part of the issue's
  code deliverable); the Erlang gate `rebar3 eunit && rebar3 ct` stays green

## Risks & trade-offs

- **The no-warnings criterion is the fragile one.** Starlight and Astro
  sometimes emit warnings the project did not cause (a deprecation notice, a
  missing-optional notice). If one is genuinely unavoidable, the build still
  exits 0 and the relaxed reading ("no Soma-caused warnings") applies. Dev should
  treat any warning as a thing to fix first and only fall back to the relaxed
  form after confirming it comes from upstream, not from our config.

- **Self-hosted fonts add weight to the dependency tree.** Pulling `@fontsource`
  packages for Inter and IBM Plex Mono is the price of having the family names
  land in the built CSS without a runtime CDN. The alternative — a CDN `<link>`
  — would keep the lockfile smaller but would not put the family names in our own
  bundled CSS as reliably, and it adds a third-party network dependency at page
  load. Self-hosting is the better fit for a docs site that should build and
  serve hermetically.

- **Diagram SVGs are duplicated, not linked.** Copying the five SVGs into
  `site/public/` means there are now two copies of each. A later edit to a
  diagram has to update both. A symlink would avoid that but would break the
  hermetic build and the "present under `site/public/`" check on a fresh
  checkout. The duplication is the deliberate cost of a self-contained site.

- **Route paths are pinned to directory format.** If a later slice flips
  `build.format` to file format for any reason, every `<route>/index.html` check
  here breaks. The format choice is load-bearing for the route criteria and
  should not be changed without updating them.
