-module(soma_cli_real_planning_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/contracts/cli-real-planning-test-contract.md").
-define(CLI_DOC, "docs/cli.md").
-define(USAGE_DOC, "docs/usage.md").
-define(SERVER_SUITE, "apps/soma_actor/test/soma_cli_server_SUITE.erl").

%% Criterion (#199): the real-planning contract names every proving module/suite
%% and case that backs the CLI/config planning product surface.
test_doc_names_cli_real_planning_suites_and_cases() ->
    Doc = read_file(?CONTRACT_DOC),
    ?assert(byte_size(Doc) > 0),
    ?assert(contains(Doc, <<"soma_config_tests">>)),
    ?assert(contains(Doc, <<"test_load_carries_plan_true">>)),
    ?assert(contains(Doc, <<"test_load_missing_provider_named_error">>)),
    ?assert(contains(Doc, <<"test_load_missing_openai_base_url_named_error">>)),
    ?assert(contains(Doc, <<"test_load_missing_openai_model_named_error">>)),
    ?assert(contains(Doc, <<"soma_cli_main_tests">>)),
    ?assert(contains(Doc, <<"test_daemon_missing_api_key_prints_diagnostic_nonzero">>)),
    ?assert(contains(Doc, <<"soma_cli_server_SUITE">>)),
    ?assert(contains(Doc, <<"test_ask_real_provider_plan_returns_step_outputs">>)),
    ?assert(contains(Doc, <<"test_ask_real_provider_plan_rejects_disallowed_tool">>)),
    ?assert(contains(Doc, <<"test_real_provider_plan_api_key_leaks_nowhere">>)),
    ?assert(contains(Doc, <<"soma_cli_real_planning_contract_tests">>)),
    ?assert(contains(Doc, <<"test_cli_planning_tests_use_fixed_provider_response_seam">>)),
    ?assert(contains(Doc, <<"test_usage_docs_document_plan_true">>)),
    ?assert(contains(Doc, <<"test_cli_docs_document_plan_true_and_result_shape">>)).

doc_names_cli_real_planning_suites_and_cases_test() ->
    test_doc_names_cli_real_planning_suites_and_cases().

%% Criterion (#199): `docs/usage.md' describes the `plan = true' switch and the
%% policy-bounded planned ask result shape.
test_usage_docs_document_plan_true() ->
    Doc = read_file(?USAGE_DOC),
    ?assert(contains(Doc, <<"plan = true">>)),
    ?assert(contains(Doc, <<"(run-steps ...)">>)),
    ?assert(contains(Doc, <<"(allow ...)">>)),
    ?assert(contains(Doc, <<"(outputs ((s1 (value \"planned\"))))">>)).

usage_docs_document_plan_true_test() ->
    test_usage_docs_document_plan_true().

%% Criterion (#199): `docs/cli.md' documents the config switch and shows the
%% completed planned `soma ask' result shape with step outputs.
test_cli_docs_document_plan_true_and_result_shape() ->
    Doc = read_file(?CLI_DOC),
    ?assert(contains(Doc, <<"plan = true">>)),
    ?assert(contains(Doc, <<"real-provider-planning">>)),
    ?assert(contains(Doc, <<"(outputs ((s1 (value \"planned\"))))">>)).

cli_docs_document_plan_true_and_result_shape_test() ->
    test_cli_docs_document_plan_true_and_result_shape().

%% Criterion (#199): every real-provider planning config in the CLI socket tests
%% is paired with the fixed provider response seam before an ask runs, so the gate
%% cannot open a live model-provider socket.
test_cli_planning_tests_use_fixed_provider_response_seam() ->
    Src = read_file(?SERVER_SUITE),
    ?assert(count(Src, <<"Loaded#{response => {200, Body}}">>) >= 3),
    ?assert(count(Src, <<"test_ask_real_provider_plan_returns_step_outputs">>) > 0),
    ?assert(count(Src, <<"test_ask_real_provider_plan_rejects_disallowed_tool">>) > 0),
    ?assert(count(Src, <<"test_real_provider_plan_api_key_leaks_nowhere">>) > 0).

cli_planning_tests_use_fixed_provider_response_seam_test() ->
    test_cli_planning_tests_use_fixed_provider_response_seam().

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

count(Haystack, Needle) ->
    length(binary:matches(Haystack, Needle)).
