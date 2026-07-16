-module(soma_run_index_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_atomic_claim_rejects_second_live_run_id/1]).
-export([test_run_sup_restart_releases_old_claim_before_reuse/1]).
-export([test_run_index_restart_fences_preexisting_suspended_run/1]).

all() ->
    [test_atomic_claim_rejects_second_live_run_id,
     test_run_sup_restart_releases_old_claim_before_reuse,
     test_run_index_restart_fences_preexisting_suspended_run].

init_per_testcase(_Case, Config) ->
    application:unset_env(soma_runtime, event_store_log),
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    _ = application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok.

%% A RunId is one live ownership key, not a textual label that two attempts may
%% share. Drive two real supervisor starts concurrently: exactly one soma_run
%% claims the id before journalling, while the other init fails with the winning
%% pid. Only the winner may appear in the index, supervisor, and event trail.
test_atomic_claim_rejects_second_live_run_id(_Config) ->
    Store = event_store_pid(),
    RunId = <<"run-index-atomic-claim">>,
    Opts = long_run_opts(RunId, Store),
    Parent = self(),
    Gate = make_ref(),
    Start =
        fun(Label) ->
                receive
                    {go, Gate} ->
                        Parent ! {started, Label,
                                  soma_run_sup:start_run(Opts)}
                end
        end,
    CallerA = spawn(fun() -> Start(a) end),
    CallerB = spawn(fun() -> Start(b) end),
    CallerA ! {go, Gate},
    CallerB ! {go, Gate},
    ResultA = receive_start(a),
    ResultB = receive_start(b),
    Winner = winning_pid(ResultA, ResultB),
    try
        ?assertEqual({ok, Winner}, soma_run_index:lookup(RunId)),
        ?assertEqual({ok, Winner}, soma_run_sup:find_run(RunId, 1000)),
        ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
        ?assertEqual([Winner], active_run_pids()),
        Types = event_types(Store, RunId),
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"tool.started">>, Types))
    after
        exit(Winner, kill),
        ok = wait_for_process_dead(Winner, 100)
    end.

%% Killing only soma_run_sup terminates even a scheduler-suspended child through
%% OTP parent ownership. Its linked tool worker must die too, and the independent
%% index must release the claim only after that exact owner is dead. A fresh
%% run_sup generation can then start a paused recovery child under the same id;
%% no second tool boundary is emitted while ownership changes generation.
test_run_sup_restart_releases_old_claim_before_reuse(_Config) ->
    Store = event_store_pid(),
    RunId = <<"run-index-old-supervisor-orphan">>,
    Opts = long_run_opts(RunId, Store),
    {ok, RunPid} = soma_run_sup:start_run(Opts),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    WorkerPid = tool_call_pid(Store, RunId),
    OldRunSup = whereis(soma_run_sup),
    true = erlang:suspend_process(RunPid),
    exit(OldRunSup, kill),
    NewRunSup = wait_for_registered_replacement(
                  soma_run_sup, OldRunSup, 100),
    ?assert(is_pid(NewRunSup)),
    ?assertNotEqual(OldRunSup, NewRunSup),
    ok = wait_for_process_dead(RunPid, 100),
    ok = wait_for_process_dead(WorkerPid, 100),
    ok = wait_for_index_absent(RunId, 100),
    ?assertEqual([], active_run_pids()),

    Steps = maps:get(steps, Opts),
    PausedOpts = Opts#{pending => Steps,
                       outputs => #{},
                       start_paused => true},
    {ok, FreshRunPid} = soma_run_sup:start_run(PausedOpts),
    try
        ?assertEqual({ok, FreshRunPid}, soma_run_index:lookup(RunId)),
        ?assertEqual({ok, FreshRunPid}, soma_run_sup:find_run(RunId)),
        ?assertEqual({ok, FreshRunPid},
                     soma_run_sup:find_run(RunId, 1000)),
        Types = event_types(Store, RunId),
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"tool.started">>, Types)),
        ?assertEqual(0, count(<<"run.resumed">>, Types))
    after
        FreshRunPid ! cancel,
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100)
    end.

%% The inverse generation change is also fenced. Killing only soma_run_index
%% leaves run_sup alive, but the new index init must discover and unconditionally
%% kill every pre-existing soma_run -- including one that cannot schedule --
%% before it serves lookup/claim. Once lookup returns, the old run and worker are
%% dead, run_sup has no stale child, and a paused recovery child can claim the
%% same id without emitting a second execution boundary.
test_run_index_restart_fences_preexisting_suspended_run(_Config) ->
    Store = event_store_pid(),
    RunId = <<"run-index-generation-fence">>,
    Opts = long_run_opts(RunId, Store),
    {ok, OldRunPid} = soma_run_sup:start_run(Opts),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    OldWorkerPid = tool_call_pid(Store, RunId),
    RunSupPid = whereis(soma_run_sup),
    OldIndexPid = whereis(soma_run_index),
    true = erlang:suspend_process(OldRunPid),
    exit(OldIndexPid, kill),
    NewIndexPid = wait_for_registered_replacement(
                    soma_run_index, OldIndexPid, 100),
    ?assert(is_pid(NewIndexPid)),
    ?assertNotEqual(OldIndexPid, NewIndexPid),
    %% This call cannot be answered until init's process fence has completed.
    ?assertEqual({error, not_found},
                 soma_run_index:lookup(RunId, 2000)),
    ?assertEqual(RunSupPid, whereis(soma_run_sup)),
    ok = wait_for_process_dead(OldRunPid, 100),
    ok = wait_for_process_dead(OldWorkerPid, 100),
    ok = wait_for_no_active_runs(100),

    Steps = maps:get(steps, Opts),
    PausedOpts = Opts#{pending => Steps,
                       outputs => #{},
                       start_paused => true},
    {ok, FreshRunPid} = soma_run_sup:start_run(PausedOpts),
    try
        ?assertEqual({ok, FreshRunPid}, soma_run_index:lookup(RunId)),
        ?assertEqual({ok, #{run_id => RunId, status => awaiting_start}},
                     soma_run:identity(FreshRunPid)),
        Types = event_types(Store, RunId),
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"tool.started">>, Types)),
        ?assertEqual(0, count(<<"run.resumed">>, Types))
    after
        FreshRunPid ! cancel,
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100)
    end.

long_run_opts(RunId, Store) ->
    #{run_id => RunId,
      session_id => <<"run-index-session">>,
      session_pid => self(),
      event_store => Store,
      steps => [#{id => hold, tool => sleep,
                  args => #{ms => 60000}, timeout_ms => 60000}]}.

receive_start(Label) ->
    receive
        {started, Label, Result} -> Result
    after 5000 ->
        ct:fail({start_result_timeout, Label})
    end.

winning_pid({ok, Winner}, {error, {run_id_in_use, Winner}}) ->
    Winner;
winning_pid({error, {run_id_in_use, Winner}}, {ok, Winner}) ->
    Winner;
winning_pid(ResultA, ResultB) ->
    ct:fail({unexpected_claim_results, ResultA, ResultB}).

wait_for_registered_replacement(_Name, _OldPid, 0) ->
    ct:fail(supervisor_restart_timeout);
wait_for_registered_replacement(Name, OldPid, Attempts) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= OldPid -> Pid;
        _ ->
            timer:sleep(20),
            wait_for_registered_replacement(Name, OldPid, Attempts - 1)
    end.

wait_for_index_absent(_RunId, 0) ->
    ct:fail(run_index_did_not_release_dead_owner);
wait_for_index_absent(RunId, Attempts) ->
    case soma_run_index:lookup(RunId, 200) of
        {error, not_found} -> ok;
        _ ->
            timer:sleep(20),
            wait_for_index_absent(RunId, Attempts - 1)
    end.

wait_for_no_active_runs(0) ->
    ct:fail(run_supervisor_kept_stale_child);
wait_for_no_active_runs(Attempts) ->
    case active_run_pids() of
        [] -> ok;
        _ ->
            timer:sleep(20),
            wait_for_no_active_runs(Attempts - 1)
    end.

wait_for_process_dead(_Pid, 0) ->
    ct:fail(process_still_alive);
wait_for_process_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(20),
            wait_for_process_dead(Pid, Attempts - 1)
    end.

wait_for_event(_Store, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(Store, RunId, Type, Attempts) ->
    case lists:member(Type, event_types(Store, RunId)) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_event(Store, RunId, Type, Attempts - 1)
    end.

tool_call_pid(Store, RunId) ->
    [Pid | _] = [maps:get(tool_call_pid, Event)
                 || Event <- soma_event_store:by_run(Store, RunId),
                    maps:get(event_type, Event) =:= <<"tool.started">>],
    Pid.

event_types(Store, RunId) ->
    [maps:get(event_type, Event)
     || Event <- soma_event_store:by_run(Store, RunId)].

active_run_pids() ->
    [Pid || {_ChildId, Pid, worker, [soma_run]} <-
                supervisor:which_children(soma_run_sup),
            is_pid(Pid)].

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, worker, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    ?assertEqual(Pid, whereis(soma_runtime_event_store)),
    Pid.

count(Type, Types) ->
    length([Value || Value <- Types, Value =:= Type]).
