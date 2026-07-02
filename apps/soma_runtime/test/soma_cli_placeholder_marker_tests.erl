%% @doc Criterion 12: the placeholder runtime tests use only repo-created
%% stub executables.
%%
%% This is a compile-time / source-scan assertion -- no call chain. It reads
%% `soma_cli_placeholder_SUITE.erl' (the placeholder runtime test source this
%% issue (#218) added) and asserts every cli manifest `executable => ...'
%% value in that file is the locally-bound `Helper' variable produced by one
%% of its own `write_*_helper/0,1' functions -- never a literal path to a
%% pre-existing system binary. It also asserts the source never calls
%% `os:find_executable' and never spells a quoted absolute system path (a
%% literal `"/bin/' or `"/usr/' string) as an executable target. Note the
%% helper scripts' own `#!/bin/sh' shebang text legitimately contains `/bin/'
%% -- it is never preceded by a quote character there, so the quoted-literal
%% check does not false-positive on it.
%%
%% Sibling precedent: `soma_cli_1b_marker_tests' / `soma_cli_2_marker_tests'
%% (`apps/soma_actor/test/'), which scan an explicit include list of test
%% sources for forbidden markers. Adapted here to a single-file include list
%% (this issue added exactly one placeholder runtime suite) and to
%% stub-executable markers instead of real-provider/socket markers.
-module(soma_cli_placeholder_marker_tests).

-include_lib("eunit/include/eunit.hrl").

%% The placeholder runtime test source this issue (#218) added, under
%% `apps/soma_runtime/test/'. Explicit include list -- not a glob -- so the
%% scanner never scans itself.
placeholder_sources() ->
    [<<"soma_cli_placeholder_SUITE.erl">>].

test_placeholder_runtime_tests_use_repo_created_stub_executables() ->
    lists:foreach(fun(File) ->
                          Src = read_test_source(File),
                          assert_no_find_executable(File, Src),
                          assert_no_quoted_system_path(File, Src),
                          assert_every_executable_is_helper(File, Src)
                  end, placeholder_sources()).

placeholder_runtime_tests_use_repo_created_stub_executables_test() ->
    test_placeholder_runtime_tests_use_repo_created_stub_executables().

%% The source never resolves an executable by looking it up on PATH.
assert_no_find_executable(File, Src) ->
    ?assertEqual({File, nomatch},
                 {File, binary:match(Src, <<"os:find_executable">>)}).

%% The source never spells a quoted absolute path into a pre-existing system
%% binary directory as a literal. The helper scripts' shebang text
%% (`#!/bin/sh') legitimately contains `/bin/', but there the slash is never
%% immediately preceded by a quote character, so this check does not match
%% it.
assert_no_quoted_system_path(File, Src) ->
    ?assertEqual({File, nomatch},
                 {File, binary:match(Src, <<"\"/bin/">>)}),
    ?assertEqual({File, nomatch},
                 {File, binary:match(Src, <<"\"/usr/">>)}).

%% Every `executable => ...' manifest field in the source names the
%% locally-bound `Helper' variable -- the return value of one of this file's
%% own `write_*_helper/0,1' functions -- and nothing else.
assert_every_executable_is_helper(File, Src) ->
    All = count(Src, <<"executable => ">>),
    AsHelper = count(Src, <<"executable => Helper,">>),
    ?assertEqual({File, All}, {File, AsHelper}).

count(Src, Needle) ->
    length(binary:matches(Src, Needle)).

%% Resolve the placeholder runtime test source under the test app's `test/'
%% directory. Under EUnit `code:lib_dir(soma_runtime)' points at
%% `_build/test/lib/soma_runtime', whose `test/' subdir holds the copied test
%% sources.
read_test_source(File) ->
    Path = filename:join([code:lib_dir(soma_runtime), "test",
                          binary_to_list(File)]),
    {ok, Src} = file:read_file(Path),
    Src.
