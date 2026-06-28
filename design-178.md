# site: polish — 404, quick-start, nav links, OG meta (English)

## Current state

The English-only site under `site/` (Astro 5 + Starlight `^0.34.0`) is built out:
a standalone landing at `site/src/pages/index.astro`, docs pages under
`site/src/content/docs/`, and a hand-written sidebar in `site/astro.config.mjs`
(Starlight auto-generation is off, so every nav item is listed by hand). Four
small gaps remain, and none of them is load-bearing.

- There is no 404 page. A bad URL gets Astro's bare default, which has no link
  back into the site. `site/src/pages/` holds only `index.astro`.
- There is no quick-start doc. The landing has a short "Quick start" code block
  (`soma daemon` / `soma run` / `soma status`), but no docs page walks through
  building and testing with `rebar3` and driving the `file_read → echo →
  file_write` demo.
- The sidebar has no Home link, so a docs reader can't get back to `/` from the
  nav. The `social` config is unset, so docs pages render no GitHub link in the
  Starlight header. (The GitHub URL does appear in the body prose of
  `reference/roadmap.md` and on the landing, but not in the docs chrome.)
- The landing `<head>` has a `<title>` and a `description` meta, but no Open
  Graph or Twitter Card tags, so a link to `https://soma.fists.cc/` unfurls with
  no card on social and chat apps.

Verification on this site is by bash harnesses under `site/test/` that run
`npm ci && npm run build` and grep the built HTML in `site/dist/`. There is no
rebar3 involvement — the Erlang gate does not touch `site/`.

## Approach

Four self-contained changes, each landing its own files and its own build-output
check. The scope is locked to the issue's criteria; no other site changes.

**404 page.** Add `site/src/pages/404.astro` as a standalone Astro page (same
shape as `index.astro`, not a Starlight docs page) so it builds to
`site/dist/404.html`. It carries a link whose `href` is `/`. A standalone page
keeps the 404 from depending on Starlight's docs layout and matches how the
landing is already authored. Reuse the landing's nav/footer styling from
`landing.css` so it looks like the rest of the site.

**Quick-start doc.** Add `site/src/content/docs/start/quick-start.md` as a
Starlight page, built to `site/dist/start/quick-start/index.html`. It ports the
README "Quick start": build and test with `rebar3` (`rebar3 compile` / `rebar3
eunit` / `rebar3 ct`), drive a run in the shell, and the `file_read → echo →
file_write` demo. The page must contain the token `rebar3`. Prose is the
author's call as long as it reads in the Soma voice and the token is present.
Then add its sidebar entry to the **Start Here** group in `astro.config.mjs`,
right after the Overview link, so the rendered sidebar links to
`/start/quick-start/`.

**Nav links.** Two parts, both in `astro.config.mjs`.

- Home link: add a sidebar entry whose `link` is `/` and whose label is `Home`.
  Starlight renders a sidebar item with an absolute external-looking link as a
  plain anchor with `href="/"`. Put it where it reads naturally (a top entry, or
  inside Start Here). The criterion only asserts a Home link with `href="/"` is
  in the rendered sidebar, not where it sits.
- GitHub link: set Starlight's `social` config so the header renders a GitHub
  link. In `^0.34.0` `social` is an array of `{ icon, label, href }`; use the
  `href` `https://github.com/ZhenchongLi/soma`. Starlight renders this into the
  header of every docs page, so it shows up in
  `dist/concepts/architecture/index.html`.

**OG / Twitter meta.** Add the meta tags to the landing's hand-written `<head>`
in `index.astro`. The landing is a standalone page, so there's no Starlight head
to extend — the tags go in literally. Add `og:title`, `og:description`,
`og:type` (content `website`), `og:url` (content `https://soma.fists.cc/`), and
`twitter:card` (content `summary`). `summary` over `summary_large_image` because
there is no OG image — a large-image card with no image renders worse than a
plain summary. No image PNG is added; that's out of scope.

No new dependency. Everything uses Astro/Starlight features already installed.

## Acceptance criteria → tests

These are build-output assertions, not rebar3 tests. Each one runs `npm ci &&
npm run build` in `site/` and inspects the produced HTML under `site/dist/`,
matching the existing `site/test/*.sh` harness convention. Where a harness file
is named below, it's the new or existing script that proves the criterion.

### Criterion 1 — build is clean
- Call chain: none (build-output read). `cd site && npm ci && npm run build`.
- Test entry: the build command's exit code and its captured stdout/stderr.
- Test: `site/test/build.sh` already asserts exit 0; extend the check (or a sibling
  script) to also assert no line in the build output contains `error` or
  `warning`. A missing-page sidebar link or a broken internal link is the usual
  source of a warning, so this guards the other three changes.

### Criterion 2 — 404 page links home
- Call chain: none (build-output read).
- Test entry: grep `site/dist/404.html`.
- Test: `test_404_links_home` — assert `site/dist/404.html` exists and contains an
  anchor whose href is `/` (`href="/"`). New harness `site/test/notfound-home-link.sh`.

### Criterion 3 — quick-start page carries the rebar3 token
- Call chain: none (build-output read).
- Test entry: grep `site/dist/start/quick-start/index.html`.
- Test: `test_quick_start_has_rebar3` — assert the file exists and contains the token
  `rebar3`. New harness `site/test/start-quick-start.sh`.

### Criterion 4 — sidebar links to quick-start in Start Here
- Call chain: none (build-output read).
- Test entry: grep a built docs page (the sidebar renders into every docs page;
  `dist/concepts/architecture/index.html` is the representative entry, same as
  the existing `sidebar-start-here.sh`).
- Test: `test_sidebar_quick_start` — assert the page contains the `Start Here` group
  label and an `href="/start/quick-start/"` link. Extend `site/test/sidebar-start-here.sh`
  (it already checks the Overview link of the same group).

### Criterion 5 — sidebar has a Home link to /
- Call chain: none (build-output read).
- Test entry: grep a built docs page (`dist/concepts/architecture/index.html`).
- Test: `test_sidebar_home_link` — assert the rendered sidebar contains a Home link
  whose href is `/` (`href="/"`). New harness `site/test/sidebar-home-link.sh`.

### Criterion 6 — docs page carries the GitHub link
- Call chain: none (build-output read).
- Test entry: grep `site/dist/concepts/architecture/index.html`.
- Test: `test_docs_github_link` — assert the page contains a link to
  `https://github.com/ZhenchongLi/soma` (the Starlight header social link).
  New harness `site/test/docs-github-link.sh`. Distinct from the existing
  `landing-github-link.sh`, which checks `dist/index.html`.

### Criterion 7 — landing has og:title
- Call chain: none (build-output read).
- Test entry: grep `site/dist/index.html`.
- Test: `test_og_title` — assert a meta tag with `property="og:title"` is present.
  New harness `site/test/landing-og-meta.sh` (covers criteria 7–11 together).

### Criterion 8 — landing has og:description
- Call chain: none (build-output read).
- Test entry: grep `site/dist/index.html`.
- Test: `test_og_description` — assert a meta tag with `property="og:description"`
  is present. Same harness `site/test/landing-og-meta.sh`.

### Criterion 9 — landing has og:type = website
- Call chain: none (build-output read).
- Test entry: grep `site/dist/index.html`.
- Test: `test_og_type` — assert a meta tag with `property="og:type"` and content
  `website`. Same harness `site/test/landing-og-meta.sh`.

### Criterion 10 — landing has og:url = https://soma.fists.cc/
- Call chain: none (build-output read).
- Test entry: grep `site/dist/index.html`.
- Test: `test_og_url` — assert a meta tag with `property="og:url"` and content
  `https://soma.fists.cc/`. Same harness `site/test/landing-og-meta.sh`.

### Criterion 11 — landing has twitter:card = summary
- Call chain: none (build-output read).
- Test entry: grep `site/dist/index.html`.
- Test: `test_twitter_card` — assert a meta tag with `name="twitter:card"` and
  content `summary`. Same harness `site/test/landing-og-meta.sh`.

### Criterion 12 — every existing route still builds
- Call chain: none (build-output read).
- Test entry: check each expected file exists under `site/dist/` after a build.
- Test: `test_all_routes_present` — assert the full set of HTML files exists:
  `index.html`, `start/overview/index.html`, the 8 `concepts/*/index.html`, the 4
  `guides/*/index.html`, and both `reference/*/index.html`. New harness
  `site/test/routes-still-build.sh`. This is the regression guard that the four
  changes don't drop or rename an existing route.

## Risks & trade-offs

- The OG and Twitter tags are checked by string-matching the rendered `<head>`.
  The tags are real and unfurl correctly, but with no OG image the social card is
  text-only. That's the deliberate trade-off in the issue (image is out of
  scope); `twitter:card` is `summary`, not `summary_large_image`, so a missing
  image doesn't degrade the card.
- The "no warning lines" check in criterion 1 is a grep over build output. It can
  false-positive if a legitimate log line happens to contain the substring
  `warning` (for example a dependency name). If that bites, the check narrows to
  lines that look like a build diagnostic rather than dropping the guard. The
  benefit — catching a missing-page sidebar link, the most likely regression from
  the nav and quick-start changes — is worth the small fragility.
- The GitHub link in criterion 6 depends on Starlight's `social` config shape in
  `^0.34.0`. The criterion asserts the rendered link, not the config shape, so if
  the installed minor version takes a different `social` form, the author adapts
  the config without changing what the test asserts.
- Criterion 12 hard-codes the current route list (overview, 8 concepts, 4 guides,
  2 reference, landing). It is a snapshot, so adding a future docs page means
  updating the list. That's the point — it's a deliberate guard against silently
  dropping a route during this change.
