%% @doc CLI.4 live-task registry proofs.
-module(soma_cli_task_registry_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion #4: a task entry registered by a short-lived process remains owned
%% by, and readable from, the registry after the registering process exits.
test_registered_task_survives_registering_process_exit() ->
    {ok, Registry} = soma_cli_task_registry:start_link(),
    try
        TaskId = <<"task-registry-survival">>,
        Task = #{pid => self(),
                 status => running,
                 correlation_id => <<"corr-registry-survival">>},
        Parent = self(),
        {Registrar, Ref} = spawn_monitor(
                             fun() ->
                                     Result = soma_cli_task_registry:register(TaskId, Task),
                                     Parent ! {registered, self(), Result}
                             end),

        receive
            {registered, Registrar, ok} ->
                ok
        after 1000 ->
                ?assert(false)
        end,
        receive
            {'DOWN', Ref, process, Registrar, normal} ->
                ok;
            {'DOWN', Ref, process, Registrar, Reason} ->
                ?assertEqual(normal, Reason)
        after 1000 ->
                ?assert(false)
        end,

        ?assertEqual({ok, Task}, soma_cli_task_registry:lookup(TaskId))
    after
        unlink(Registry),
        exit(Registry, shutdown)
    end.

registered_task_survives_registering_process_exit_test() ->
    test_registered_task_survives_registering_process_exit().

%% Criterion #5: once a detached run the registry owns reaches a terminal
%% completed state, the existing task entry is updated from running to completed.
test_detached_run_completion_updates_registry_status() ->
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    {ok, Registry} = soma_cli_task_registry:start_link(),
    try
        TaskId = <<"task-registry-completion">>,
        CorrId = <<"corr-registry-completion">>,
        RunId = <<"run-registry-completion">>,
        Store = event_store_pid(),
        Steps = [#{id => hold, tool => sleep, args => #{ms => 50}}],

        {ok, RunPid} = soma_run_sup:start_run(
                         #{run_id => RunId,
                           session_id => TaskId,
                           correlation_id => CorrId,
                           session_pid => Registry,
                           event_store => Store,
                           steps => Steps}),
        ok = soma_cli_task_registry:register(
               TaskId,
               #{pid => RunPid,
                 status => running,
                 correlation_id => CorrId,
                 run_id => RunId}),

        ok = wait_for_run_completed(Store, RunId, 100),
        ?assertEqual(completed,
                     wait_for_registry_status(TaskId, completed, 100))
    after
        unlink(Registry),
        exit(Registry, shutdown),
        application:stop(soma_runtime)
    end.

detached_run_completion_updates_registry_status_test() ->
    test_detached_run_completion_updates_registry_status().

wait_for_registry_status(TaskId, _Expected, 0) ->
    {ok, Task} = soma_cli_task_registry:lookup(TaskId),
    maps:get(status, Task);
wait_for_registry_status(TaskId, Expected, N) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, #{status := Expected}} ->
            Expected;
        {ok, _Task} ->
            timer:sleep(20),
            wait_for_registry_status(TaskId, Expected, N - 1);
        Other ->
            Other
    end.

wait_for_run_completed(_Store, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(Store, RunId, N) ->
    Events = soma_event_store:by_run(Store, RunId),
    Types = [maps:get(event_type, Event) || Event <- Events],
    case lists:member(<<"run.completed">>, Types) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_run_completed(Store, RunId, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
