-module(soma_l5_mock_only_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SUITE_PATH, "apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl").

%% Issue #117 criterion 10: the L.5 test run opens no real LLM call and no
%% external network socket -- mock LLM only. This is a by-construction invariant
%% of `soma_actor_lisp_repair_SUITE': every LLM directive it drives the actor
%% with (including each repair call, whose output is supplied through the same
%% mock `llm' map) is the `proposal' mock directive -- the same mock the v0.5,
%% L.1, L.2 and L.3 suites use, which returns a pre-built proposal without
%% `perform_call/1' reaching `soma_llm_openai' -- and no L.5 test opt carries a
%% real-provider config. This guard pins that invariant against the actual suite
%% source so a later edit that slips a real provider (or a non-`proposal'
%% directive) into the L.5 run is caught by the gate. Modeled on
%% `soma_l3_mock_only_tests'.

read_suite() ->
    case file:read_file(?SUITE_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?SUITE_PATH, Reason})
    end.

%% Count non-overlapping occurrences of Needle in Haystack.
count(Haystack, Needle) ->
    length(binary:matches(Haystack, Needle)).

%% Criterion 10 (part a): every `llm => #{directive => ...}' the suite uses is
%% the `proposal' mock directive -- i.e. there is no LLM directive other than
%% `proposal'. Asserted by counting: every occurrence of `directive =>' is an
%% occurrence of `directive => proposal'.
test_every_llm_directive_is_the_proposal_mock() ->
    Suite = read_suite(),
    DirectiveCount = count(Suite, <<"directive =>">>),
    ProposalCount = count(Suite, <<"directive => proposal">>),
    ?assert(DirectiveCount > 0),
    %% Every LLM directive the suite drives the actor with is the `proposal' mock.
    ?assertEqual(DirectiveCount, ProposalCount).

%% Criterion 10 (part b): no L.5 test opt carries a real-provider config -- the
%% suite source names no real OpenAI provider module, no API key / base URL opt,
%% and no network host/port. Each marker must be absent.
test_no_real_provider_config_in_suite() ->
    Suite = read_suite(),
    Markers = [<<"soma_llm_openai">>,
               <<"api_key">>,
               <<"base_url">>,
               <<"api_base">>,
               <<"http">>,
               <<"https">>],
    [?assertEqual({Marker, 0}, {Marker, count(Suite, Marker)})
     || Marker <- Markers],
    ok.

every_llm_directive_is_the_proposal_mock_test() ->
    test_every_llm_directive_is_the_proposal_mock().

no_real_provider_config_in_suite_test() ->
    test_no_real_provider_config_in_suite().
