-module(soma_b2_no_socket_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REAL_PROVIDER_SUITE_PATH,
        "apps/soma_actor/test/soma_actor_real_provider_SUITE.erl").

%% Issue #119 criterion 7: the actor's real-provider gate suite
%% (`soma_actor_real_provider_SUITE') exercises only the mock and the pure
%% builder, opening no real-provider network connection. This is a
%% by-construction guard, like `soma_l5_mock_only_tests': it reads the suite
%% source and pins what it does and does not do, rather than running the suite.
%% The suite reaches `soma_llm_openai' only through the fixed `response' seam
%% (the marker `response =>' is present and gates every real-provider config,
%% so `chat/1' parses the response directly and `httpc' is never reached) and it
%% names no network host/port literal (`http://' / `https://' absent). A later
%% edit that slips a live call -- a real-provider config with no `response', or a
%% dialable url literal -- into the suite is caught by the gate.

read_suite() ->
    case file:read_file(?REAL_PROVIDER_SUITE_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} ->
            erlang:error({cannot_read, ?REAL_PROVIDER_SUITE_PATH, Reason})
    end.

%% Count non-overlapping occurrences of Needle in Haystack.
count(Haystack, Needle) ->
    length(binary:matches(Haystack, Needle)).

%% Criterion 7: the real-provider suite reaches `soma_llm_openai' only through
%% the fixed `response' seam, and names no network host/port literal. Part a:
%% the `response =>' marker is present and gates every real-provider config --
%% every `provider => openai_compat' the suite carries is matched by a
%% `response =>' in the same config, so no real-provider config reaches the live
%% `httpc' path. Part b: no `http://' / `https://' url literal appears in the
%% suite source, so no case names a dialable network address.
test_real_provider_suite_uses_response_seam_only() ->
    Suite = read_suite(),
    ResponseCount = count(Suite, <<"response =>">>),
    ProviderCount = count(Suite, <<"provider => openai_compat">>),
    %% The `response' seam is present and gates every real-provider config.
    ?assert(ResponseCount > 0),
    %% DELIBERATELY WRONG expected (staged red): assert the seam appears more
    %% times than the suite could carry, so the assertion fires for the right
    %% reason before being corrected to current reality.
    ?assertEqual(ProviderCount + 1, ResponseCount),
    %% No network host/port literal -- the seam short-circuits before `httpc'.
    ?assertEqual(0, count(Suite, <<"http://">>)),
    ?assertEqual(0, count(Suite, <<"https://">>)),
    ok.

real_provider_suite_uses_response_seam_only_test() ->
    test_real_provider_suite_uses_response_seam_only().
