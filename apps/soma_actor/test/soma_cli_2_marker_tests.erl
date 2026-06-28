%% @doc CLI.2 Criterion 10: the CLI.2 test sources carry no real-provider marker
%% and open no non-local socket.
%%
%% This is a compile-time / source-scan assertion -- no call chain. It reads the
%% CLI.2 test source files this issue (#122) added and asserts none of them
%% contains a real-provider marker (`soma_llm_openai' / `api_key' / `base_url' /
%% `http' / `https') and none opens a non-`{local, _}' socket (no `{inet, ...}'
%% family option, no `gen_tcp:listen' / `gen_tcp:connect' to a host/port). The
%% ask chain stays on local Unix domain sockets and reaches the LLM only through
%% the mock directive seam, never a real provider.
%%
%% Sibling precedent: `soma_cli_1b_marker_tests'. The scan list is an explicit
%% include list of the CLI.2 ask-flow suite/test files under
%% `apps/soma_actor/test/'. It deliberately excludes this module's own source --
%% this file necessarily contains the marker strings as literals (it searches for
%% them), so a glob would always match its own needles.
-module(soma_cli_2_marker_tests).

-include_lib("eunit/include/eunit.hrl").

%% The real-provider markers no CLI.2 test source may contain.
-define(PROVIDER_MARKERS,
        [<<"soma_llm_openai">>, <<"api_key">>, <<"base_url">>,
         <<"http">>, <<"https">>]).

%% The CLI.2 ask-flow test sources this issue added, under
%% `apps/soma_actor/test/' (client SUITE + contract + cli.md pin). Explicit
%% include list -- not a glob -- so the scanner never scans itself.
%%
%% `soma_cli_server_SUITE.erl' is deliberately NOT on this list: the CLI.8b
%% daemon real-provider regression-guard test it now hosts
%% (`test_real_provider_api_key_leaks_nowhere') legitimately names the secret
%% token in its title, so the provider-marker literal scan no longer fits it.
%% That suite stays hermetic by the fixed-`response' seam, asserted in the tests
%% themselves, not by a source-literal scan (per design-137 criterion 11).
cli_2_sources() ->
    [<<"soma_cli_SUITE.erl">>,
     <<"soma_cli_2_contract_tests.erl">>,
     <<"soma_cli_md_ask_tests.erl">>].

test_cli_2_sources_have_no_real_provider_or_socket_marker() ->
    lists:foreach(fun(File) ->
                          Src = read_test_source(File),
                          assert_no_provider_marker(File, Src),
                          assert_no_non_local_socket(File, Src)
                  end, cli_2_sources()).

cli_2_sources_have_no_real_provider_or_socket_marker_test() ->
    test_cli_2_sources_have_no_real_provider_or_socket_marker().

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

%% Resolve a CLI.2 test source under the test app's `test/' directory. Under
%% EUnit `code:lib_dir(soma_actor)' points at `_build/test/lib/soma_actor',
%% whose `test/' subdir holds the copied test sources.
read_test_source(File) ->
    Path = filename:join([code:lib_dir(soma_actor), "test",
                          binary_to_list(File)]),
    {ok, Src} = file:read_file(Path),
    Src.
