%% @doc CLI.3 Criterion 11: the CLI.3 test sources carry no real-provider marker
%% and open no non-local socket.
%%
%% This is a compile-time / source-scan assertion -- no call chain. It reads the
%% CLI.3 read-flow test source files this issue (#124) added and asserts none of
%% them contains a real-provider marker (`soma_llm_openai' / `api_key' /
%% `base_url' / `http' / `https') and none opens a non-`{local, _}' socket (no
%% `{inet, ...}' family option, no `gen_tcp:listen' / `gen_tcp:connect' to a
%% host/port). The status / trace read path stays on local Unix domain sockets
%% and never reaches a real provider -- so the whole gate runs with no network.
%%
%% Sibling precedent: `soma_cli_2_marker_tests' / `soma_cli_1b_marker_tests'.
%% Unlike those, the CLI.3 scan list spans three apps -- the LFE reader tests
%% live under `soma_lfe', the lisp render tests under `soma_event_store', and the
%% CLI client/server/contract tests under `soma_actor' -- so each entry carries
%% its owning app and is resolved against that app's `lib_dir'. The list is an
%% explicit include list -- not a glob -- so the scanner never scans itself (this
%% file necessarily contains the marker strings as literals).
-module(soma_cli_3_marker_tests).

-include_lib("eunit/include/eunit.hrl").

%% The real-provider markers no CLI.3 test source may contain.
%% STAGED RED: `gen_tcp' is deliberately listed here so the provider-marker
%% assertion fires against the local-socket connects in the CLI SUITEs --
%% corrected to current reality in the green commit.
-define(PROVIDER_MARKERS,
        [<<"soma_llm_openai">>, <<"api_key">>, <<"base_url">>,
         <<"http">>, <<"https">>, <<"gen_tcp">>]).

%% The CLI.3 read-flow test sources this issue added, each paired with the app
%% whose `test/' dir holds the copied source. Explicit include list -- not a
%% glob -- so the scanner never scans itself.
cli_3_sources() ->
    [{soma_lfe, <<"soma_lfe_read_tests.erl">>},
     {soma_event_store, <<"soma_lisp_tests.erl">>},
     {soma_actor, <<"soma_cli_server_SUITE.erl">>},
     {soma_actor, <<"soma_cli_SUITE.erl">>},
     {soma_actor, <<"soma_cli_md_read_tests.erl">>},
     {soma_actor, <<"soma_cli_3_contract_tests.erl">>}].

test_cli_3_sources_have_no_real_provider_or_socket_marker() ->
    lists:foreach(fun({App, File}) ->
                          Src = read_test_source(App, File),
                          assert_no_provider_marker(File, Src),
                          assert_no_non_local_socket(File, Src)
                  end, cli_3_sources()).

cli_3_sources_have_no_real_provider_or_socket_marker_test() ->
    test_cli_3_sources_have_no_real_provider_or_socket_marker().

%% No real-provider marker appears anywhere in the source.
assert_no_provider_marker(File, Src) ->
    lists:foreach(
      fun(Marker) ->
              ?assertEqual({File, Marker, nomatch},
                           {File, Marker, binary:match(Src, Marker)})
      end, ?PROVIDER_MARKERS).

%% Every socket open is on a `{local, _}' address: there is no `{inet, ...}'
%% family option and no `gen_tcp:listen' on a bare port. A `gen_tcp:connect' is
%% allowed only in its `{local, _}' form -- the count of `connect(' calls must
%% match the count of `connect({local,' calls.
assert_no_non_local_socket(File, Src) ->
    ?assertEqual({File, nomatch},
                 {File, binary:match(Src, <<"{inet">>)}),
    ?assertEqual({File, nomatch},
                 {File, binary:match(Src, <<"gen_tcp:listen">>)}),
    AllConnects = count(Src, <<"gen_tcp:connect(">>),
    LocalConnects = count(Src, <<"gen_tcp:connect({local,">>),
    ?assertEqual({File, AllConnects}, {File, LocalConnects}).

count(Src, Needle) ->
    length(binary:matches(Src, Needle)).

%% Resolve a CLI.3 test source under its owning app's `test/' directory. Under
%% EUnit `code:lib_dir(App)' points at `_build/test/lib/<App>', whose `test/'
%% subdir holds the copied test sources.
read_test_source(App, File) ->
    Path = filename:join([code:lib_dir(App), "test",
                          binary_to_list(File)]),
    {ok, Src} = file:read_file(Path),
    Src.
