-module(soma_b2_no_socket_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REAL_PROVIDER_SUITE_PATH,
        "apps/soma_actor/test/soma_actor_real_provider_SUITE.erl").

-define(USAGE_DOC_PATH, "docs/usage.md").

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
    %% Count real-provider config *literals* (`#{provider => openai_compat'),
    %% not prose: the map-literal marker excludes the comment that names the
    %% provider in passing, so this is the number of real-provider configs the
    %% suite actually carries.
    ProviderCount = count(Suite, <<"#{provider => openai_compat">>),
    %% The `response' seam is present and gates every real-provider config:
    %% there is at least one, and each one carries a `response'.
    ?assert(ProviderCount > 0),
    ?assertEqual(ProviderCount, ResponseCount),
    %% No network host/port literal -- the seam short-circuits before `httpc'.
    ?assertEqual(0, count(Suite, <<"http://">>)),
    ?assertEqual(0, count(Suite, <<"https://">>)),
    ok.

real_provider_suite_uses_response_seam_only_test() ->
    test_real_provider_suite_uses_response_seam_only().

read_usage_doc() ->
    case file:read_file(?USAGE_DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} ->
            erlang:error({cannot_read, ?USAGE_DOC_PATH, Reason})
    end.

%% Issue #119 criterion 8: `docs/usage.md' documents configuring an actor with a
%% real-provider `model_config' and running the opt-in smoke. This is a
%% doc-presence guard -- it reads the doc source and asserts the markers are
%% there, rather than running anything. The new section must show starting an
%% actor whose `model_config' carries `provider => openai_compat' (the two
%% markers appear together, in the same window) and point at the opt-in smoke.
test_usage_documents_actor_real_provider_config() ->
    Doc = read_usage_doc(),
    %% A new section heading naming the real-provider actor config.
    ?assert(count(Doc, <<"actor with a real LLM provider">>) > 0),
    %% The two markers appear together: the section shows an actor `model_config'
    %% carrying `provider => openai_compat'. Pin them in one window so a stray
    %% `model_config' elsewhere and a stray provider mention can't satisfy this.
    ?assert(markers_together(Doc, <<"model_config">>,
                             <<"provider => openai_compat">>)),
    %% It points the reader at the opt-in smoke.
    ?assert(count(Doc, <<"soma_llm_smoke:run()">>) > 0),
    ok.

%% True when both needles occur within one ~600-byte window of each other --
%% close enough to be the same section rather than two unrelated mentions.
markers_together(Haystack, A, B) ->
    case {binary:matches(Haystack, A), binary:matches(Haystack, B)} of
        {[], _} -> false;
        {_, []} -> false;
        {AsMatches, BsMatches} ->
            As = [Pos || {Pos, _Len} <- AsMatches],
            Bs = [Pos || {Pos, _Len} <- BsMatches],
            lists:any(fun(Pa) ->
                              lists:any(fun(Pb) -> abs(Pa - Pb) =< 600 end, Bs)
                      end, As)
    end.

usage_documents_actor_real_provider_config_test() ->
    test_usage_documents_actor_real_provider_config().
