-module(soma_parser_hardening_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/parser-hardening-test-contract.md").

%% Issue #235 criterion 6: the durable parser-hardening contract must map each
%% acceptance criterion to its exact proving module and case exactly once.
test_parser_hardening_contract_maps_every_guarantee() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,
    Mappings =
        [{<<"## Criterion 1 ">>,
          <<"soma_lfe_parser_hardening_tests:test_external_lisp_symbols_have_zero_atom_count_delta">>},
         {<<"## Criterion 2 ">>,
          <<"soma_parser_hardening_compat_tests:test_safe_reader_default_preserves_compile_maps_and_wire_round_trips">>},
         {<<"## Criterion 3 ">>,
          <<"soma_lfe_parser_hardening_tests:test_unknown_grammar_symbols_have_fixed_named_diagnostics">>},
         {<<"## Criterion 4 ">>,
          <<"soma_config_tests:test_toml_key_path_has_no_atom_creation_bif">>},
         {<<"## Criterion 5 ">>,
          <<"soma_tool_config_SUITE:test_daemon_boot_config_tool_names_are_binary_and_atom_safe">>},
         {<<"## Criterion 6 ">>,
          <<"soma_parser_hardening_contract_tests:test_parser_hardening_contract_maps_every_guarantee">>}],
    ?assertEqual(length(Mappings),
                 length(binary:matches(Doc, <<"## Criterion ">>))),
    lists:foreach(
        fun({Heading, Proof}) ->
            ?assertEqual(1, length(binary:matches(Doc, Heading))),
            ?assertEqual(1, length(binary:matches(Doc, Proof)))
        end,
        Mappings
    ).

parser_hardening_contract_maps_every_guarantee_test() ->
    test_parser_hardening_contract_maps_every_guarantee().
