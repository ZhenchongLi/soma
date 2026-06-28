# [cc] site: docs — Guides + Reference pages (English)

## Current state

`site/` is an Astro + Starlight project, English-only. It already ships a
landing page (`src/pages/index.astro`), a Start Here group with one Overview
page, and a Concepts group with eight pages (from #169). The sidebar is set
explicitly in `site/astro.config.mjs` — Starlight auto-generation is off, so
every group the nav shows is listed by hand. Today that file has exactly two
groups: Start Here and Concepts.

Content pages live as Markdown under `src/content/docs/<group>/<slug>.md`. Each
has a frontmatter block with `title` and `description`. The route comes from the
file path: `concepts/architecture.md` builds to
`dist/concepts/architecture/index.html` because `astro.config.mjs` sets
`build.format: 'directory'`. A sidebar link is only valid if its target page
exists — a link to a missing page is a build warning, and the site is verified
by `npm run build`, not by Erlang tests.

What's missing: the runtime has four operator-facing docs (`docs/usage.md`,
`docs/lfe-dsl.md`, `docs/cli.md`, `docs/release.md`) and two reference docs
(`docs/roadmap.md`, `docs/zh/erlang-otp-primer.zh.md`) that have no home on the
site. A reader on the site can learn the concepts but can't find the API, the
DSL syntax, the CLI, the release steps, the roadmap, or the Erlang primer.

## Approach

Add two sidebar groups — Guides and Reference — and six content pages under
them, each ported from a named `docs/` source. Nothing about Start Here or
Concepts changes.

Six new Markdown files under `src/content/docs/`:

- `guides/usage.md` from `docs/usage.md`
- `guides/lfe-dsl.md` from `docs/lfe-dsl.md`
- `guides/cli.md` from `docs/cli.md`
- `guides/release.md` from `docs/release.md` plus the README "Release" section
- `reference/roadmap.md` from `docs/roadmap.md`
- `reference/erlang-otp-primer.md` from `docs/zh/erlang-otp-primer.zh.md`

Each file gets a Starlight frontmatter block (`title`, `description`) followed
by the ported body. The sources are already Markdown, so porting is mostly
copying the body and dropping the leading `#` H1 (Starlight renders the title
from frontmatter, so a body H1 would double it). The lfe-dsl source uses
```lisp fences — keep them; Starlight's Shiki highlighter handles `lisp`.

The `reference/erlang-otp-primer` page is the one real adaptation. Its source
is Chinese (`docs/zh/erlang-otp-primer.zh.md`). It gets translated into clear
technical English aimed at readers new to Erlang — same concepts and structure
(Erlang, BEAM, process, mailbox, OTP, supervisor, `gen_server`, `gen_statem`,
application, release), not a word-for-word translation. Code identifiers and
fenced code stay as-is; only prose is rewritten.

Then add the two groups to the `sidebar` array in `astro.config.mjs`, after the
Concepts group:

```
{ label: 'Guides', items: [
  { label: 'Usage', link: '/guides/usage/' },
  { label: 'LFE DSL', link: '/guides/lfe-dsl/' },
  { label: 'CLI', link: '/guides/cli/' },
  { label: 'Release', link: '/guides/release/' },
] },
{ label: 'Reference', items: [
  { label: 'Roadmap', link: '/reference/roadmap/' },
  { label: 'Erlang/OTP primer', link: '/reference/erlang-otp-primer/' },
] },
```

The required content tokens are all already present in the sources, so a
faithful port carries them through: `start_run` (usage.md line 65, inside the
`soma_agent_session:start_run` call example), `soma_lfe` (lfe-dsl.md, 23
occurrences), `soma run` (cli.md, 11 occurrences), `rebar3 as prod` (release.md
line 39, the `rebar3 as prod tar` command), `roadmap` (roadmap.md title and
body), `gen_server` (the primer, 12 occurrences — these are code identifiers,
so they survive translation unchanged).

One token to watch: `start_run` appears once in `usage.md`. The port must keep
that code example intact. The Dev should not summarize the API section away.

## Acceptance criteria → tests

The site has no Erlang test surface. Verification is `npm run build` plus
`grep` against the built `dist/` HTML — the same harness pattern the existing
`site/test/*.sh` scripts use (resolve `site/` from the script's own location,
`npm ci && npm run build`, then assert on `dist/...`). Each criterion below maps
to one such script under `site/test/`.

### Criterion 1 — clean build, no error/warning lines
- Call chain: none (build-output assertion). `npm ci && npm run build`, capture
  combined stdout+stderr, scan for any line matching `error|warning`
  (case-insensitive).
- Test entry: the build output text — same as the existing `build-clean.sh`.
- Test: `guides-reference-build-clean.sh` in `site/test/`

### Criterion 2 — guides/usage builds and contains `start_run`
- Call chain: none (direct dist-file read). Build, then assert
  `dist/guides/usage/index.html` exists and contains `start_run`.
- Test entry: the built HTML file.
- Test: `guide-usage.sh` in `site/test/`

### Criterion 3 — guides/lfe-dsl builds and contains `soma_lfe`
- Call chain: none (direct dist-file read). Assert
  `dist/guides/lfe-dsl/index.html` exists and contains `soma_lfe`.
- Test entry: the built HTML file.
- Test: `guide-lfe-dsl.sh` in `site/test/`

### Criterion 4 — guides/cli builds and contains `soma run`
- Call chain: none (direct dist-file read). Assert
  `dist/guides/cli/index.html` exists and contains `soma run`.
- Test entry: the built HTML file.
- Test: `guide-cli.sh` in `site/test/`

### Criterion 5 — guides/release builds and contains `rebar3 as prod`
- Call chain: none (direct dist-file read). Assert
  `dist/guides/release/index.html` exists and contains `rebar3 as prod`.
- Test entry: the built HTML file.
- Test: `guide-release.sh` in `site/test/`

### Criterion 6 — reference/roadmap builds and contains `roadmap`
- Call chain: none (direct dist-file read). Assert
  `dist/reference/roadmap/index.html` exists and contains `roadmap`.
- Test entry: the built HTML file.
- Test: `reference-roadmap.sh` in `site/test/`

### Criterion 7 — reference/erlang-otp-primer builds and contains `gen_server`
- Call chain: none (direct dist-file read). Assert
  `dist/reference/erlang-otp-primer/index.html` exists and contains
  `gen_server`.
- Test entry: the built HTML file.
- Test: `reference-erlang-otp-primer.sh` in `site/test/`

### Criterion 8 — primer page content is English, not Chinese
- Call chain: none (direct dist-file read). Read
  `dist/reference/erlang-otp-primer/index.html` and assert no CJK characters
  appear in the rendered article body — grep for a Unicode CJK range
  (`[\x{4e00}-\x{9fff}]`) and require zero matches in the page's prose. Code
  identifiers like `gen_server` are ASCII, so they don't trip this. A positive
  English-presence check (an English sentence fragment from the translation)
  can be paired in, but the load-bearing assertion is "no Chinese".
- Test entry: the built HTML file.
- Test: `reference-primer-english.sh` in `site/test/`

### Criterion 9 — sidebar Guides group links to all 4 guides routes
- Call chain: none (direct dist-file read). The sidebar renders into every docs
  page, so any built page is a representative entry. Read a built page's HTML,
  assert the label `Guides` is present and an `href="/guides/<slug>/"` exists
  for each of `usage`, `lfe-dsl`, `cli`, `release`.
- Test entry: the built HTML file — same shape as the existing
  `sidebar-concepts.sh`.
- Test: `sidebar-guides.sh` in `site/test/`

### Criterion 10 — sidebar Reference group links to both reference routes
- Call chain: none (direct dist-file read). Read a built page's HTML, assert the
  label `Reference` is present and an `href="/reference/<slug>/"` exists for
  each of `roadmap`, `erlang-otp-primer`.
- Test entry: the built HTML file.
- Test: `sidebar-reference.sh` in `site/test/`

### Criterion 11 — Start Here and Concepts groups still render unchanged
- Call chain: none (direct dist-file read). Read a built page's HTML, assert the
  labels `Start Here` and `Concepts` are present and every existing route
  (`/start/overview/` plus the eight `/concepts/<slug>/`) still has its href.
  The existing `sidebar-concepts.sh` covers the Concepts half; this adds the
  Start Here half. Both are reused as-is for the regression.
- Test entry: the built HTML file.
- Test: existing `sidebar-concepts.sh` plus `sidebar-start-here.sh` in
  `site/test/`

### Criterion 12 — landing page still builds
- Call chain: none (direct dist-file read). Assert `dist/index.html` exists.
- Test entry: the built HTML file — same as the existing `landing-still-builds.sh`.
- Test: existing `landing-still-builds.sh` in `site/test/`

### Criterion 13 — start/overview still builds
- Call chain: none (direct dist-file read). Assert
  `dist/start/overview/index.html` exists.
- Test entry: the built HTML file.
- Test: `start-overview-still-builds.sh` in `site/test/` (an existing #169 test
  already asserts this route; reuse it if present, else add this one).

### Criterion 14 — concepts/architecture still builds
- Call chain: none (direct dist-file read). Assert
  `dist/concepts/architecture/index.html` exists and still contains `soma_run`.
- Test entry: the built HTML file — the existing `concept-architecture.sh`
  already proves exactly this.
- Test: existing `concept-architecture.sh` in `site/test/`

## Risks & trade-offs

The "no error or warning lines" scan in Criterion 1 is broad — it greps the
whole build log for `error|warning` case-insensitively. If a ported page's body
text happens to contain the word "warning" or "error" in a way the build echoes
back (for example a logged page path, or a verbose Vite line), the scan trips on
content rather than on a real problem. This is the same harness #169 used and it
passed there, so the risk is low, but it's a content-coupled check, not a pure
build-status check. If it false-trips, the fix is to narrow the scan, not to
weaken the criterion.

The primer translation is a judgment call, not a mechanical port. The "no CJK
characters" check (Criterion 8) proves the prose was actually translated, but it
can't prove the translation is faithful or readable — that's a human review
concern at merge, outside what `grep` can assert.

The six sources are large (usage.md is ~930 lines, roadmap ~356). Porting them
verbatim is a lot of text, but it's the issue's intent ("ported faithfully").
The trade-off is page length over curation — these are reference pages, so long
is acceptable. No source content is dropped beyond the leading H1.
