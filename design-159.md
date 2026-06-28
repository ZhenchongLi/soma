# [cc] site: bilingual landing page (jido-style, soma red)

## Current state

The `site/` scaffold from #154 stands up Astro 5 + Starlight 0.34 with two locales:
English at `/` and 简体中文 at `/zh/`. `astro.config.mjs` sets
`build.format: 'directory'`, so every route lands as `<route>/index.html`. The
soma-red tokens (`#a1232b` bound to `--sl-color-accent`) and the Inter / IBM Plex
Mono `@font-face` rules live in `site/src/styles/custom.css`, imported through
Starlight's `customCss`. The five architecture SVGs sit in `site/public/`.

Both roots today are Starlight `splash` pages:
`site/src/content/docs/index.mdx` and `site/src/content/docs/zh/index.mdx`. A
splash page is Starlight's stock hero layout — a tagline, a CTA button, and some
body prose. It is not the custom landing the issue wants. The hero phrase the
build needs (`supervised OTP process tree`) is already present in the English
splash body, but the thesis phrase (`agents fail in operational ways`), the
per-layer feature cards, the Shiki code block, the embedded
`supervision-tree.svg`, and the GitHub call-to-action are not. The Chinese splash
tagline says `受监督的进程树`, not the exact `受监督的 OTP 进程树` the build pins.

The seed docs (`site/src/content/docs/start/overview.md` and its zh twin) build to
`/start/overview/` and `/zh/start/overview/`. They stay where they are.

The test harness pattern is set: `site/test/*.sh`, one script per criterion, each
resolving `site/` from its own location, running `npm ci && npm run build`, then
grepping or stat-ing the `dist/` output. Twelve scripts exist for the #154
criteria. This slice adds scripts in the same shape.

## Approach

Replace both root pages with a custom landing while staying inside Starlight, so
the i18n machinery (the `<html lang>` attribute, the language picker, the locale
routing) and the global stylesheet keep working untouched.

Two ways to render a custom page in Starlight: a `splash`-template MDX page with
the hero/prose authored as MDX, or a standalone Astro page using Starlight's
`<StarlightPage>` component. The landing wants a top nav, a thesis band, a feature
grid, an embedded SVG section, and a "why Erlang/OTP" trio — full custom layout,
not a hero + markdown body. So each root becomes an Astro page that renders its
own markup.

Decisions:

- **Root pages become `.astro` files under `site/src/pages/`.** `index.astro`
  builds to `/index.html`, `zh/index.html` to `/zh/index.html`. This takes the
  roots out of the Starlight docs content collection. The docs collection still
  owns `start/overview` and its zh twin, so those routes are unaffected.
- **The `<html lang>` attribute.** A bare Astro page does not get Starlight's
  `lang` attribute for free. The English page sets `lang="en"` on its `<html>`,
  the Chinese page sets `lang="zh-CN"`, matching the `locales` config in
  `astro.config.mjs`. These are authored directly in each page's layout so the
  values are not guessed at build time.
- **The accent token and fonts.** `site/src/styles/custom.css` already binds
  `#a1232b` to `--sl-color-accent` and declares the two font families. The
  landing pages import that same stylesheet, so the bundled CSS under
  `dist/_astro/` keeps the accent binding and the font references the #154
  criteria already guard. No token is redefined on the landing.
- **The language toggle.** Each root carries an explicit anchor to the other
  locale: the English page links to `/zh/`, the Chinese page links to `/`. This
  is a plain `<a href>` in the nav, not Starlight's `<starlight-lang-select>`
  control (that control renders on docs pages, not on a standalone Astro page).
  The criteria ask for an `href` of `/zh/` on the English root and `/` on the
  Chinese root — a direct anchor satisfies that and is what a reader clicks.
- **The code block.** Astro's built-in Markdown/MDX uses Shiki, which emits
  `class="astro-code"` on highlighted blocks. The quick-start snippet is authored
  as a fenced code block so the build runs it through Shiki. The criterion greps
  for `class="astro-code"`, so the snippet must reach the page through Astro's
  code highlighter, not as hand-written `<pre>`.
- **The SVG.** The architecture section embeds `/supervision-tree.svg` with an
  `<img src="/supervision-tree.svg">`. The file already ships in `site/public/`,
  so the build copies it to `dist/` and the `src` reference resolves.
- **Copy is authored natively in each language.** The English page writes the
  English copy, the Chinese page writes the Chinese copy. Erlang identifiers
  (`soma_run`, `gen_statem`, `LFE DSL`) stay in their original form in both.
- **The pinned strings are the test anchors.** `supervised OTP process tree`,
  `agents fail in operational ways`, `受监督的 OTP 进程树`, and the three card
  labels `LFE DSL` / `Decision layer` / `Resume journal` appear verbatim in the
  built HTML. The surrounding prose is free.
- **Feature cards, one per layer (v0.1–v0.7.1).** The three labels the build pins
  are `LFE DSL` (v0.3), `Decision layer` (v0.5), and `Resume journal` (v0.7.1).
  The other layers get cards too, but only these three are asserted.

The old `index.mdx` and `zh/index.mdx` splash files are removed so the docs
content collection no longer claims the root routes — otherwise two sources would
both try to build `/index.html`.

## Acceptance criteria → tests

Every criterion is checked against the `dist/` output by a `site/test/*.sh`
script. None of these have a code call chain — each is a direct read of a built
file, so the call-chain field is the source-read label throughout. Test entry is
the built artifact the script inspects.

### Criterion 1 — build exits 0
- Call chain: none (direct build-exit check)
- Test entry: the exit code of `npm ci && npm run build` in `site/`
- Test: `site/test/build.sh` (already present; re-runs green against the new pages)

### Criterion 2 — English hero phrase
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html`
- Test: `site/test/landing-en-hero.sh` — greps `index.html` for the exact string
  `supervised OTP process tree`

### Criterion 3 — thesis phrase distinguishes landing from splash
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html`
- Test: `site/test/landing-en-thesis.sh` — greps `index.html` for
  `agents fail in operational ways`. The old splash never had this string, so a
  pass means the built root is the custom landing.

### Criterion 4 — Chinese hero phrase
- Call chain: none (direct source-file read)
- Test entry: `site/dist/zh/index.html`
- Test: `site/test/landing-zh-hero.sh` — greps `zh/index.html` for
  `受监督的 OTP 进程树`

### Criterion 5 — English root links to /zh/
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html`
- Test: `site/test/landing-en-to-zh.sh` — greps `index.html` for an anchor whose
  `href` is `/zh/` (`href="/zh/"`)

### Criterion 6 — Chinese root links back to /
- Call chain: none (direct source-file read)
- Test entry: `site/dist/zh/index.html`
- Test: `site/test/landing-zh-to-en.sh` — greps `zh/index.html` for an anchor
  whose `href` is `/` (`href="/"`)

### Criterion 7 — supervision SVG referenced and present
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html` and `site/dist/supervision-tree.svg`
- Test: `site/test/landing-svg.sh` — greps `index.html` for
  `/supervision-tree.svg` and stats `dist/supervision-tree.svg`

### Criterion 8 — three feature-card labels present
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html`
- Test: `site/test/landing-feature-cards.sh` — greps `index.html` for all three
  of `LFE DSL`, `Decision layer`, `Resume journal`; all three must be found

### Criterion 9 — Shiki-highlighted code block
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html`
- Test: `site/test/landing-code-shiki.sh` — greps `index.html` for
  `class="astro-code"`

### Criterion 10 — GitHub external link
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html`
- Test: `site/test/landing-github-link.sh` — greps `index.html` for an anchor
  whose `href` is `https://github.com/ZhenchongLi/soma`

### Criterion 11 — English `<html lang="en">`
- Call chain: none (direct source-file read)
- Test entry: `site/dist/index.html`
- Test: `site/test/landing-en-lang.sh` — greps `index.html` for an `<html>` tag
  carrying `lang="en"`. Starts green under the #154 splash; kept as a regression
  guard that the root replacement does not break the English `lang`.

### Criterion 12 — Chinese `<html lang="zh-CN">`
- Call chain: none (direct source-file read)
- Test entry: `site/dist/zh/index.html`
- Test: `site/test/landing-zh-lang.sh` — greps `zh/index.html` for an `<html>`
  tag carrying `lang="zh-CN"`. Note this is stricter than the #154
  `build-zh-lang.sh`, which matches `lang="zh` as a prefix. Regression guard for
  the zh `lang` surviving the root replacement.

### Criterion 13 — English docs route survives
- Call chain: none (direct source-file read)
- Test entry: `site/dist/start/overview/index.html`
- Test: `site/test/build-en-docs.sh` (already present) — stats the file. Regression
  guard that taking the roots out of the docs collection leaves the seed docs
  route intact.

### Criterion 14 — Chinese docs route survives
- Call chain: none (direct source-file read)
- Test entry: `site/dist/zh/start/overview/index.html`
- Test: `site/test/build-zh-docs.sh` (already present) — stats the file. Same
  regression guard for the zh seed docs route.

### Criterion 15 — accent token bound in bundled CSS
- Call chain: none (direct source-file read)
- Test entry: bundled CSS under `site/dist/_astro/`
- Test: `site/test/build-css-accent.sh` (already present) — greps the bundled CSS
  for `--sl-color-accent: #a1232b`. Regression guard that the landing pages still
  pull in `custom.css`.

## Risks & trade-offs

- **Standalone Astro pages give up Starlight's page chrome.** A docs page gets
  Starlight's sidebar, header, and the `<starlight-lang-select>` picker for free.
  The landing pages do not — the nav, the language toggle, and the `<html lang>`
  are authored by hand. The cost is that the landing's nav and the docs' nav are
  two separate things to keep visually consistent. The upside is full control
  over the landing layout, which a splash page can't give. The language toggle on
  the landing is a plain anchor, not the docs picker, so the two switchers behave
  differently; that is acceptable for a marketing root but worth noting.

- **The zh `lang` test is stricter than #154's.** Criterion 12 pins `lang="zh-CN"`
  exactly, while the scaffold's `build-zh-lang.sh` accepts any `lang="zh*"`. If a
  future change sets `lang="zh"` the scaffold test stays green but this one fails.
  That is intended — the criterion pins the configured locale value.

- **Removing the splash MDX files is load-bearing.** If `index.mdx` is left in
  place alongside `src/pages/index.astro`, two sources claim `/index.html` and the
  build errors on a route collision. The splash files must be deleted, not just
  edited.

- **The GitHub URL is unconfirmed for launch.** The CTA points at
  `https://github.com/ZhenchongLi/soma`. The criterion only checks the string is
  in the HTML; whether that repo is public is a launch question, not a build one,
  and is out of scope for this slice.
