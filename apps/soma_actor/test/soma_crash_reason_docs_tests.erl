%% @doc Documentation proofs for the `AGENTS.md' actor-registry and
%% crash-reason criteria (issue #187). Each test reads `AGENTS.md' at the repo
%% root and asserts the substrings that prove the criterion is documented; it
%% opens no socket and starts no app.
-module(soma_crash_reason_docs_tests).

-include_lib("eunit/include/eunit.hrl").

agents_md_path() ->
    filename:join([code:lib_dir(soma_actor), "..", "..", "..", "..",
                   "AGENTS.md"]).

read_agents_md() ->
    {ok, Bin} = file:read_file(agents_md_path()),
    Bin.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

test_agents_md_names_actor_registry() ->
    Doc = read_agents_md(),
    %% `AGENTS.md' names `soma_actor_registry' as the stable-name addressing
    %% mechanism in the actor description.
    ?assert(contains(Doc, <<"soma_actor_registry">>)),
    ?assert(contains(Doc, <<"stable">>)).

agents_md_names_actor_registry_test() ->
    test_agents_md_names_actor_registry().

test_agents_md_names_spawn_monitor() ->
    Doc = read_agents_md(),
    %% `AGENTS.md' names `spawn_monitor' as the `soma_tool_call:start/1'
    %% worker-spawn mechanism.
    ?assert(contains(Doc, <<"spawn_monitor">>)),
    ?assert(contains(Doc, <<"soma_tool_call">>)).

agents_md_names_spawn_monitor_test() ->
    test_agents_md_names_spawn_monitor().

test_agents_md_immediate_crash_keeps_real_reason() ->
    Doc = read_agents_md(),
    %% `AGENTS.md' states an immediate tool crash keeps the real exit reason
    %% instead of `noproc'.
    ?assert(contains(Doc, <<"real exit reason">>)),
    ?assert(contains(Doc, <<"noproc">>)).

agents_md_immediate_crash_keeps_real_reason_test() ->
    test_agents_md_immediate_crash_keeps_real_reason().
