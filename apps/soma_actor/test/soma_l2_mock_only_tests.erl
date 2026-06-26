-module(soma_l2_mock_only_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SUITE_PATH, "apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl").

%% Issue #107 criterion 9: the L.2 test run opens no real LLM call and no
%% external network socket -- mock LLM only. This is a by-construction invariant
%% of `soma_actor_lisp_to_lisp_SUITE': every LLM directive it drives A1 with is
%% the `proposal' mock directive (the same mock the v0.5 and L.1 suites use,
%% which returns a pre-built proposal without `perform_call/1' reaching
%% `soma_llm_openai'), and no L.2 test opt carries a real-provider config. This
%% guard pins that invariant against the actual suite source so a later edit that
%% slips a real provider (or a non-`proposal' directive) into the L.2 run is
%% caught by the gate.

read_suite() ->
    case file:read_file(?SUITE_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?SUITE_PATH, Reason})
    end.

%% Count non-overlapping occurrences of Needle in Haystack.
count(Haystack, Needle) ->
    length(binary:matches(Haystack, Needle)).

%% Criterion 9 (part a): every `llm => #{directive => ...}' the suite uses is the
%% `proposal' mock directive -- i.e. there is no LLM directive other than
%% `proposal'. Asserted by counting: every occurrence of `directive =>' is an
%% occurrence of `directive => proposal'.
test_every_llm_directive_is_the_proposal_mock() ->
    Suite = read_suite(),
    DirectiveCount = count(Suite, <<"directive =>">>),
    ProposalCount = count(Suite, <<"directive => proposal">>),
    ?assert(DirectiveCount > 0),
    %% Every LLM directive the suite drives A1 with is the `proposal' mock.
    ?assertEqual(DirectiveCount, ProposalCount).

%% Criterion 9 (part b): no L.2 test opt carries a real-provider config -- the
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
