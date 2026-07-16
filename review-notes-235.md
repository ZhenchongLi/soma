### Claude

## Verdict

changes-requested

## Real issues

- `soma_lfe_parser` still copies fresh unknown grammar heads into nested
  diagnostics. `parse_msg_fields/2`, `parse_proposal_steps/2`,
  `parse_proposal_step/2`, and `parse_ask_fields/2` format the rejected form at
  `apps/soma_lfe/src/soma_lfe_parser.erl:230`, `:536`, `:583`, and `:686`.
  A fresh short head under `msg` produced a 63-byte message; a 255-character
  head produced 375 bytes. The same defect appears under `ask` and
  `run-steps`. This fails criterion 3. Replace these external-symbol branches
  with fixed named diagnostics and pin short/long equality at the public
  compiler boundary.
- The parser-hardening contract names a test that does not exist.
  `docs/contracts/parser-hardening-test-contract.md:23` points to
  `soma_lfe_parser_hardening_tests:test_unknown_grammar_symbols_have_fixed_named_diagnostics`,
  but `apps/soma_lfe/test/soma_lfe_parser_hardening_tests.erl` contains only
  the atom-count case. The doc-drift test passes because it searches the
  document for text and never checks that the proving function exists. This
  fails criterion 6.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: - [x] One table-driven test: a fresh-symbol read through `soma_lfe_reader:read_forms/1` and accepted or rejected fresh-symbol forms through `soma_lfe:compile/2` all have zero VM atom-count delta. Artifact: `soma_lfe_parser_hardening_tests:test_external_lisp_symbols_have_zero_atom_count_delta`; `rebar3 eunit --module=soma_lfe_parser_hardening_tests` passed 1 test, 0 failures.
- Criterion 2 — pass: - [x] An explicit compatibility pin preserves current compile maps plus render-to-compile round trips across the `soma_lfe`/`soma_lisp`/CLI-wire surface. Artifact: `soma_parser_hardening_compat_tests:test_safe_reader_default_preserves_compile_maps_and_wire_round_trips`; `rebar3 eunit --module=soma_parser_hardening_compat_tests` passed 1 test, 0 failures.
- Criterion 3 — fail: - [ ] Unknown grammar symbols have fixed named diagnostics independent of symbol length. Artifact: public `soma_lfe:compile/2` probes produced nested `msg` diagnostic messages of 63 bytes for a fresh short head and 375 bytes for a fresh 255-character head; `ask` produced 57 and 357 bytes, and `run-steps` produced 63 and 347 bytes. The named proving test is absent.
- Criterion 4 — pass: - [x] The `soma_config` TOML-key production path contains no atom-creation BIF. Artifact: `soma_config_tests:test_toml_key_path_has_no_atom_creation_bif`; `rebar3 eunit --module=soma_config_tests` passed 13 tests, 0 failures, and the production option map uses literal atoms in `apps/soma_actor/src/soma_config.erl:175`.
- Criterion 5 — pass: - [x] One table-driven test: a valid fresh-named config tool has a registered binary identity with zero atom-count growth after daemon boot, and a config tool name longer than 255 characters yields `{invalid_tool_name, too_long}` with zero atom-count growth. Artifact: `soma_tool_config_SUITE:test_daemon_boot_config_tool_names_are_binary_and_atom_safe`; `rebar3 ct --suite apps/soma_actor/test/soma_tool_config_SUITE` passed all 17 tests.
- Criterion 6 — fail: - [x] The parser-hardening contract maps every guarantee above to its proving test. Artifact: `docs/contracts/parser-hardening-test-contract.md:23` maps criterion 3 to `soma_lfe_parser_hardening_tests:test_unknown_grammar_symbols_have_fixed_named_diagnostics`, but no such function exists; `soma_parser_hardening_contract_tests:test_parser_hardening_contract_maps_every_guarantee` only proves that the name appears in the document.

Full gate: `rebar3 eunit` passed 430 tests, 0 failures; `rebar3 ct` passed 559 tests, 0 failures.
