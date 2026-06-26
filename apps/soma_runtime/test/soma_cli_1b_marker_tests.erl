%% @doc CLI.1b Criterion 14: the CLI.1b test sources carry no real-provider
%% marker and open no non-local socket.
%%
%% This is a compile-time / source-scan assertion -- no call chain. It reads the
%% CLI.1b test source files this issue added and asserts none of them contains a
%% real-provider marker (`soma_llm_openai' / `api_key' / `base_url' / `http' /
%% `https') and none opens a non-`{local, _}' socket (no `{inet, ...}' family
%% option, no `gen_tcp:listen' / `gen_tcp:connect' to a host/port). The suites
%% stay on local Unix domain sockets and never reach a real provider.
%%
%% The scan list is an explicit include list of the CLI.1b suite/test files. It
%% deliberately excludes this module's own source -- this file necessarily
%% contains the marker strings as literals (it searches for them), so a glob
%% would always match its own needles.
-module(soma_cli_1b_marker_tests).

-include_lib("eunit/include/eunit.hrl").

%% The real-provider markers no CLI.1b test source may contain.
-define(PROVIDER_MARKERS,
        [<<"soma_llm_openai">>, <<"api_key">>, <<"base_url">>,
         <<"http">>, <<"https">>]).

%% The CLI.1b test sources this issue added (run-flow daemon + client + wire
%% docs + contract). Explicit include list -- not a glob -- so the scanner never
%% scans itself.
cli_1b_sources() ->
    [<<"soma_cli_server_SUITE.erl">>,
     <<"soma_cli_server_tests.erl">>,
     <<"soma_cli_SUITE.erl">>,
     <<"soma_cli_wire_docs_tests.erl">>,
     <<"soma_cli_1b_contract_tests.erl">>,
     %% RED stage: this real-provider test is NOT a CLI.1b source. Including it
     %% here makes the provider-marker assertion fire (it carries `base_url' /
     %% `https' / `soma_llm_openai'), proving the scan actually rejects markers.
     %% Removed in the green commit.
     <<"soma_llm_openai_tests.erl">>].

test_cli_1b_sources_have_no_real_provider_or_socket_marker() ->
    lists:foreach(fun(File) ->
                          Src = read_test_source(File),
                          assert_no_provider_marker(File, Src),
                          assert_no_non_local_socket(File, Src)
                  end, cli_1b_sources()).

cli_1b_sources_have_no_real_provider_or_socket_marker_test() ->
    test_cli_1b_sources_have_no_real_provider_or_socket_marker().

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

%% Resolve a CLI.1b test source under the test app's `test/' directory. Under
%% EUnit `code:lib_dir(soma_runtime)' points at `_build/test/lib/soma_runtime',
%% whose `test/' subdir holds the copied test sources.
read_test_source(File) ->
    Path = filename:join([code:lib_dir(soma_runtime), "test",
                          binary_to_list(File)]),
    {ok, Src} = file:read_file(Path),
    Src.
