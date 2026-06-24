### Claude

## Verdict
changes-requested

## Real issues

1. **No implementation exists.** The branch has one commit: `design-38.md`. The `apps/soma_lfe/` directory does not exist. There is no `soma_lfe.app.src`, no `soma_lfe.erl`, no `soma_lfe_tests.erl`. Every acceptance criterion requires code that is absent.

## Questions

None — the design doc itself is clear and correct. The dependency-direction reasoning is sound; the placeholder-behavior rationale is sound; the module layout is what the repo style demands. This is a clean design waiting for implementation.

## Nits

- design-38.md line 32: `{message, <<"not implemented">>, line, 0}` is a flat list, not a map. The spec says `{error, [map()]}`. The diagnostic shape should be `#{message => <<"not implemented">>, line => 0}`. Fix it before the implementation copy-pastes the wrong shape from the design doc.

## Functional evidence

- Criterion 1 — fail: `apps/soma_lfe/` directory does not exist; no `.app.src`; module never compiled.
- Criterion 2 — fail: `soma_lfe:compile/2` and `soma_lfe:compile_file/2` do not exist.
- Criterion 3 — fail: no `soma_lfe.app.src` to read; dependency direction is documented in `design-38.md` only, not enforced in any machine-readable artifact.
- Criterion 4 — fail: no `soma_lfe_tests.erl`; no tests written.
- Criterion 5 — fail: cannot verify no runtime changes without the new app compiling and the existing CT suites running against the full umbrella including `soma_lfe`.
