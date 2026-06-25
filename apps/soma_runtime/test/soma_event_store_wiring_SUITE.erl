%% @doc Runtime-wiring proofs for #97: how `soma_sup' starts its
%% `soma_event_store' child from the `event_store_log' app env. The store
%% internals are proven in `soma_event_store_persist_tests'; this suite proves
%% only the supervisor's wiring decision, by booting and stopping the
%% `soma_runtime' application with the env set or unset.
-module(soma_event_store_wiring_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_unset_env_store_is_in_memory_writes_no_file/1]).

all() ->
    [test_unset_env_store_is_in_memory_writes_no_file].

init_per_testcase(_Case, Config) ->
    application:unset_env(soma_runtime, event_store_log),
    TmpDir = make_tmp_dir(),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    [{tmp_dir, TmpDir} | Config].

end_per_testcase(_Case, Config) ->
    ok = application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok = del_tmp_dir(?config(tmp_dir, Config)),
    ok.

%% Criterion 1: with `event_store_log' unset, the `soma_event_store' child
%% started under `soma_sup' is in-memory and creates no log file on disk.
%%
%% The case reads the live store child out of `which_children(soma_sup)',
%% drives an append/2 through it, and asserts no file appeared in a fresh temp
%% dir it watches — the same on-disk check #96 used, against the sup-owned store.
test_unset_env_store_is_in_memory_writes_no_file(Config) ->
    TmpDir = ?config(tmp_dir, Config),
    Before = list_dir(TmpDir),

    StorePid = store_child(),
    ok = soma_event_store:append(StorePid, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a1}),
    %% The in-memory store still serves the event from memory.
    [a1] = [maps:get(event_type, E) || E <- soma_event_store:by_run(StorePid, run_a)],

    After = list_dir(TmpDir),
    %% RED (staged): deliberately wrong expected value to see the assertion fire.
    ?assertEqual([<<"events.log">>], After),
    ?assertEqual(Before, After).

%%% Helpers

%% Resolve the live `soma_event_store' child pid out of the running supervisor.
store_child() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, worker, _} = lists:keyfind(soma_event_store, 1, Children),
    Pid.

make_tmp_dir() ->
    Unique = erlang:integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(["/tmp", "soma_event_store_wiring_" ++ Unique]),
    ok = file:make_dir(Dir),
    Dir.

list_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    lists:sort(Names).

del_tmp_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    [ok = file:delete(filename:join(Dir, N)) || N <- Names],
    file:del_dir(Dir).
