# CLI.3 Dialyzer PR Report

This is the PR body text for CLI.3 criterion 12. The current GitHub state has
no pull request for branch
`issue/124-cc-cli-3-soma-status-trace-read-commands-over-the-lisp-wire`
(`gh pr view` reports no PR and
`gh pr list --head issue/124-cc-cli-3-soma-status-trace-read-commands-over-the-lisp-wire`
returns `[]`), so the branch carries the PR-ready report here until a PR body
exists.

## PR body

Dialyzer was run with `rebar3 dialyzer` on 2026-06-27. It exited non-zero with
the known baseline 4 warnings:

- `apps/soma_lfe/src/soma_lfe_reader.erl:110` - pattern can never match.
- `apps/soma_lfe/src/soma_lfe_reader.erl:119` - previous clauses completely
  cover the type.
- `apps/soma_lfe/src/soma_lfe_reader.erl:133` - empty-list pattern can never
  match.
- `apps/soma_runtime/src/soma_tool_call.erl:114` - unmatched return from the
  external OS pid reporting send.

`git diff origin/main...HEAD -- apps/soma_lfe/src/soma_lfe_reader.erl
apps/soma_runtime/src/soma_tool_call.erl` produced no output, so the warning
sites are untouched by this branch. The normal merge gate remains
`rebar3 eunit && rebar3 ct`.
