### Claude

## Verdict
approve

## Real issues

None.

## Questions

None.

## Nits

- `package.json` build script is `NODE_OPTIONS=--no-deprecation astro build`. The
  build emits zero deprecation lines without it (verified both ways), so the flag
  guards against nothing today. Harmless, but it's not cross-platform — a Windows
  `npm run build` won't parse the inline env assignment. Site CI runs on bash, so
  no consequence now. Leave it or drop it.
- `polish-build-clean.sh` scans the combined log for `error|warn`, but
  `site/.npmrc` sets `loglevel=error`, so an npm-level warning during `npm ci`
  would never reach the scan. `npm ci --loglevel=warn` emits none today, so the
  gap is theoretical. Worth knowing the harness watches Astro's output, not npm's.

## Functional evidence
- Criterion 1 — pass: `npm ci && npm run build` exits 0; full output scanned, no `error`/`warn`/`deprecat` line present (also confirmed clean with `--no-deprecation` removed and `npm ci --loglevel=warn`). `polish-build-clean.sh` → PASS.
- Criterion 2 — pass: `dist/404.html` built; `grep 'href="/"'` matches `<a class="cta primary" href="/">Back home</a>`.
- Criterion 3 — pass: `dist/start/quick-start/index.html` built; contains the `rebar3` token 4 times (`rebar3 compile`/`eunit`/`ct`/`shell`).
- Criterion 4 — pass: Start Here group hrefs in `dist/concepts/architecture/index.html` are `['/', '/start/overview/', '/start/quick-start/']` — quick-start sits in the group alongside overview, rendered with `aria-current`.
- Criterion 5 — pass: same group carries a Home item — `href="/" aria-current="false"` in `dist/concepts/architecture/index.html` (sidebar shape, distinct from the header logo link).
- Criterion 6 — pass: `dist/concepts/architecture/index.html` contains `href="https://github.com/ZhenchongLi/soma"` (Starlight header social link).
- Criterion 7 — pass: `dist/index.html` contains `property="og:title"`.
- Criterion 8 — pass: `dist/index.html` contains `property="og:description"`.
- Criterion 9 — pass: `dist/index.html` contains `property="og:type" content="website"`.
- Criterion 10 — pass: `dist/index.html` contains `property="og:url" content="https://soma.fists.cc/"`.
- Criterion 11 — pass: `dist/index.html` contains `name="twitter:card" content="summary"`.
- Criterion 12 — pass: all routes present after build — landing `index.html`, `start/overview/`, all 8 `concepts/*`, all 4 `guides/*`, both `reference/*` (plus `start/quick-start/` and `404.html`); `routes-still-build.sh` → PASS. 18 pages built.
