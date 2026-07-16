# Parser-hardening test contract

This contract maps each parser-hardening guarantee to the gate case that proves
it.

## Criterion 1 — External Lisp symbols do not grow the atom table

External reader and compiler input cannot add atoms to the VM atom table.

- Proving case: `soma_lfe_parser_hardening_tests:test_external_lisp_symbols_have_zero_atom_count_delta`

## Criterion 2 — Established compile maps and Lisp wire round trips stay compatible

Safe reader defaults preserve established compile maps and canonical Lisp wire
round trips.

- Proving case: `soma_parser_hardening_compat_tests:test_safe_reader_default_preserves_compile_maps_and_wire_round_trips`

## Criterion 3 — Unknown grammar symbols have fixed named diagnostics

Unknown grammar heads return bounded, spelling-independent named diagnostics.

- Proving case: `soma_lfe_parser_hardening_tests:test_unknown_grammar_symbols_have_fixed_named_diagnostics`

## Criterion 4 — The TOML-key production path contains no atom-creation BIF

Config TOML keys map through a fixed vocabulary without an atom-creation BIF.

- Proving case: `soma_config_tests:test_toml_key_path_has_no_atom_creation_bif`

## Criterion 5 — Daemon boot keeps config tool names binary and atom-safe

Config tool names remain binary and bounded through daemon boot and registry
admission.

- Proving case: `soma_tool_config_SUITE:test_daemon_boot_config_tool_names_are_binary_and_atom_safe`

## Criterion 6 — The parser-hardening contract maps every guarantee

This document keeps every criterion heading and fully qualified proving case
unique.

- Proving case: `soma_parser_hardening_contract_tests:test_parser_hardening_contract_maps_every_guarantee`
