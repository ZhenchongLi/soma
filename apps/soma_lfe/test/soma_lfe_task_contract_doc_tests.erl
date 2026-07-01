-module(soma_lfe_task_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

test_contract_names_task_compile_cases() ->
    Doc = read_doc("docs/contracts/task-form-test-contract.md"),
    lists:foreach(
        fun(Token) ->
            ?assert(contains(Doc, Token))
        end,
        [
            <<"soma_lfe_task_tests">>,
            <<"test_task_compiles_to_run_steps">>,
            <<"test_bare_from_lowers_to_from_step">>,
            <<"test_field_from_lowers_to_from_step_tuple">>,
            <<"test_timeout_ms_lowers_to_step_timeout_ms">>,
            <<"test_duplicate_binding_returns_diagnostic">>,
            <<"test_forward_from_binding_returns_diagnostic">>,
            <<"test_unsupported_task_control_heads_return_diagnostic">>
        ]
    ).

contract_names_task_compile_cases_test() ->
    test_contract_names_task_compile_cases().
