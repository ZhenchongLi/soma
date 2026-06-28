### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The English root `index.astro` hand-writes the full `<html><head>` — no canonical link, no Open Graph tags, no `<meta name="generator">`. The docs pages get those from Starlight; the two landing roots don't. Fine for this slice (no criterion asks for them), but the marketing roots are exactly the pages that want social-card metadata. Worth a follow-up issue, not a blocker here.
- The landing roots no longer carry Starlight's language picker — they use plain `<a href="/zh/">中文</a>` anchors. That's a one-way nav choice, deliberate per design-159.md. No issue, noting it so the next slice doesn't "fix" it back into `<starlight-lang-select>`.

## Nits
- `quickStart` snippet is duplicated verbatim in both `index.astro` and `zh/index.astro` (only the comment line differs). Two copies drift independently. Low cost to leave as-is at two pages.
- Footer and nav both emit the same GitHub link and the same language toggle. Harmless duplication, but if a third locale lands this is a copy-paste tax.

## Functional evidence
- Criterion 1 — pass: `cd site && npm ci && npm run build` ran clean, `BUILD_EXIT=0`, log tail `[build] Complete!` / `5 page(s) built in 2.58s`.
- Criterion 2 — pass: `grep -F 'supervised OTP process tree' dist/index.html` matches (hero tagline, index.astro:41).
- Criterion 3 — pass: `grep -F 'agents fail in operational ways' dist/index.html` matches (thesis band, index.astro:51); old splash `index.mdx` is deleted (`No such file or directory`), proving the root is the custom landing.
- Criterion 4 — pass: `grep -F '受监督的 OTP 进程树' dist/zh/index.html` matches (zh hero h1, zh/index.astro:36).
- Criterion 5 — pass: `grep -F 'href="/zh/"' dist/index.html` matches (nav lang-toggle + footer).
- Criterion 6 — pass: `grep -oE 'href="/"' dist/zh/index.html` → 2 exact occurrences; the `-F 'href="/"'` test does not false-match `href="/zh/..."`.
- Criterion 7 — pass: `grep -F '/supervision-tree.svg' dist/index.html` matches and `dist/supervision-tree.svg` exists.
- Criterion 8 — pass: all three labels `LFE DSL`, `Decision layer`, `Resume journal` present in `dist/index.html` (feature cards, index.astro:61/68/75).
- Criterion 9 — pass: `grep -F 'class="astro-code' dist/index.html` matches — the `<Code lang="bash">` component routes the quick-start snippet through Shiki.
- Criterion 10 — pass: `grep -F 'href="https://github.com/ZhenchongLi/soma"' dist/index.html` matches.
- Criterion 11 — pass: `<html lang="en">` is the literal html tag in `dist/index.html`.
- Criterion 12 — pass: `<html lang="zh-CN">` is the literal html tag in `dist/zh/index.html`.
- Criterion 13 — pass: `dist/start/overview/index.html` exists after the build (seed docs route survives).
- Criterion 14 — pass: `dist/zh/start/overview/index.html` exists after the build.
- Criterion 15 — pass: `grep -Eqr -- '--sl-color-accent:[[:space:]]*#a1232b\b' dist/_astro` matches — bundled CSS binds the soma red accent.
