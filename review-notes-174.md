### Claude

## Verdict
changes-requested

## Real issues

- `guides/usage.md` drops 625 lines of the source. The port is 311 lines; `docs/usage.md` is 933. It keeps "Starting the runtime" through "Cancelling a run", then jumps straight to "Failure reasons" — cutting 16 source sections in between: the entire Agent actor API (`soma_actor`), the v0.5 decision layer (proposals, policy gate, budget, actor-to-actor messages), the real-LLM provider config (`~/.soma/config`, `SOMA_LLM_API_KEY`), the opt-in smoke test, and the local CLI server/client modules. This is the only usage page on the site, so a reader cannot find the actor API, the decision loop, or how to wire a real model. The design said "No source content is dropped beyond the leading H1" and "The Dev should not summarize the API section away." It was. The `start_run` token survives near the top, so Criterion 2's grep passes while the page is unfaithful. Port the missing sections (source lines 290–914) into `site/src/content/docs/guides/usage.md`.

## Questions

- The other five ports are faithful (headings match the source after the H1 drop): `cli.md`, `lfe-dsl.md`, `release.md`, `roadmap.md`, and the primer. The primer is fully translated to English, all 18 sections plus glossary, zero CJK in the rendered page. No action needed on those.

## Nits

- `roadmap.md` heading `## node B — real LLM provider (接真模型)` had its Chinese parenthetical stripped in the port. Correct call — flagging only so it's a deliberate record, not a silent edit.

## Functional evidence
- Criterion 1 — pass: `npm ci` exit 0, `npm run build` exit 0; `grep -niE 'error|warning'` on the full build log returns nothing (exit 1). 17 pages built in 2.69s.
- Criterion 2 — pass: `grep -F start_run dist/guides/usage/index.html` matches. (Token present, but see Real issues — the page is not a faithful port.)
- Criterion 3 — pass: `grep -F soma_lfe dist/guides/lfe-dsl/index.html` matches.
- Criterion 4 — pass: `grep -F "soma run" dist/guides/cli/index.html` matches.
- Criterion 5 — pass: `grep -F "rebar3 as prod" dist/guides/release/index.html` matches.
- Criterion 6 — pass: `grep -F roadmap dist/reference/roadmap/index.html` matches.
- Criterion 7 — pass: `grep -F gen_server dist/reference/erlang-otp-primer/index.html` matches.
- Criterion 8 — pass: `grep -oP '[\x{4e00}-\x{9fff}]' dist/reference/erlang-otp-primer/index.html` returns 0 CJK chars; ported file has all 18 source sections rendered in English (e.g. "What `gen_server` is", "What a supervisor is").
- Criterion 9 — pass: `dist/guides/usage/index.html` sidebar contains label `Guides` and `href="/guides/usage/"`, `href="/guides/lfe-dsl/"`, `href="/guides/cli/"`, `href="/guides/release/"` — all 4 present.
- Criterion 10 — pass: same page contains label `Reference` and `href="/reference/roadmap/"`, `href="/reference/erlang-otp-primer/"` — both present.
- Criterion 11 — pass: same page contains labels `Start Here` and `Concepts`; `href="/start/overview/"` and `href="/concepts/architecture/"` present; `astro.config.mjs` Start Here + Concepts groups unchanged vs `origin/main`.
- Criterion 12 — pass: `dist/index.html` exists.
- Criterion 13 — pass: `dist/start/overview/index.html` exists.
- Criterion 14 — pass: `dist/concepts/architecture/index.html` exists and `grep -F soma_run` matches.
