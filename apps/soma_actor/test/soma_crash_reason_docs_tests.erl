%% @doc Documentation proofs for the `CLAUDE.md' actor-registry and
%% crash-reason criteria (issue #187). Each test reads `CLAUDE.md' at the repo
%% root and asserts the substrings that prove the criterion is documented; it
%% opens no socket and starts no app.
-module(soma_crash_reason_docs_tests).

-include_lib("eunit/include/eunit.hrl").

claude_md_path() ->
    filename:join([code:lib_dir(soma_actor), "..", "..", "..", "..",
                   "CLAUDE.md"]).

read_claude_md() ->
    {ok, Bin} = file:read_file(claude_md_path()),
    Bin.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

test_claude_md_names_actor_registry() ->
    Doc = read_claude_md(),
    %% `CLAUDE.md' names `soma_actor_registry' as the stable-name addressing
    %% mechanism in the actor description.
    ?assert(contains(Doc, <<"soma_actor_registry">>)),
    ?assert(contains(Doc, <<"stable">>)).

claude_md_names_actor_registry_test() ->
    test_claude_md_names_actor_registry().

test_claude_md_names_spawn_monitor() ->
    Doc = read_claude_md(),
    %% `CLAUDE.md' names `spawn_monitor' as the `soma_tool_call:start/1'
    %% worker-spawn mechanism.
    ?assert(contains(Doc, <<"spawn_monitor">>)),
    ?assert(contains(Doc, <<"soma_tool_call">>)).

claude_md_names_spawn_monitor_test() ->
    test_claude_md_names_spawn_monitor().
