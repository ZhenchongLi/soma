-module(soma_l4_mock_only_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #112 criterion 7: the L.4 test run opens no real LLM call and no
%% external network socket. The L.4 slice is a pure term->Lisp renderer
%% (`soma_lisp:render/1') plus a trace render and two doc/guard tests -- none of
%% them touch a provider or a socket. This guard reads the L.4 test sources and
%% asserts no real-provider marker (`soma_llm_openai', `api_key', `base_url',
%% `http', `https', a socket open) appears, so a later edit that slips a real
%% provider or a network call into the L.4 run is caught by the gate. Modeled on
%% `soma_l3_mock_only_tests'. The guard scans the other L.4 test sources, not
%% itself -- this module necessarily names the markers it searches for.

-define(L4_TEST_SOURCES,
        ["apps/soma_event_store/test/soma_lisp_tests.erl",
         "apps/soma_event_store/test/soma_trace_lisp_SUITE.erl",
         "apps/soma_event_store/test/soma_l4_contract_doc_tests.erl"]).

read_source(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

%% Count non-overlapping occurrences of Needle in Haystack.
count(Haystack, Needle) ->
    length(binary:matches(Haystack, Needle)).

%% Criterion 7: no L.4 test source names a real provider, an API key / base URL
%% opt, a network scheme, or a socket open. Each marker must be absent from
%% every L.4 test source.
test_no_real_provider_or_socket_in_l4_tests() ->
    Markers = [<<"soma_llm_openai">>,
               <<"api_key">>,
               <<"base_url">>,
               <<"api_base">>,
               <<"http">>,
               <<"https">>,
               <<"gen_tcp">>,
               <<"ssl:connect">>],
    [?assertEqual({Path, Marker, 0}, {Path, Marker, count(read_source(Path), Marker)})
     || Path <- ?L4_TEST_SOURCES, Marker <- Markers],
    %% No real-provider or socket marker appears in any L.4 test source.
    TotalMarkers = lists:sum([count(read_source(Path), Marker)
                              || Path <- ?L4_TEST_SOURCES, Marker <- Markers]),
    ?assertEqual(0, TotalMarkers).

no_real_provider_or_socket_in_l4_tests_test() ->
    test_no_real_provider_or_socket_in_l4_tests().
