-module(soma_service_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_supervised_service_restarts_and_serves_again/1]).

all() ->
    [test_supervised_service_restarts_and_serves_again].

init_per_testcase(test_supervised_service_restarts_and_serves_again, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo, sleep]}),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(test_supervised_service_restarts_and_serves_again, _Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    application:unset_env(soma_actor, service_policy),
    application:unload(soma_actor),
    ok.

test_supervised_service_restarts_and_serves_again(_Config) ->
    ServicePid = whereis(soma_service),
    ?assert(is_pid(ServicePid)),
    ?assert(is_process_alive(ServicePid)),

    SlowEnvelope = tool_envelope(
                     <<"service-restart-slow">>, sleep,
                     #{ms => 1000}),
    {ok, #{task_id := SlowTaskId, status := accepted}} =
        soma_service:invoke(SlowEnvelope),
    {ok, #{status := running}} = soma_service:status(SlowTaskId),
    OwnedRunPid = wait_for_monitored_run(ServicePid, 100),
    ?assert(is_process_alive(OwnedRunPid)),

    exit(ServicePid, kill),
    ReplacementPid = wait_for_replacement(ServicePid, 100),
    ?assert(is_process_alive(ReplacementPid)),

    EchoEnvelope = tool_envelope(
                     <<"service-restart-echo">>, echo,
                     #{value => <<"served again">>}),
    {ok, #{task_id := EchoTaskId, status := accepted}} =
        soma_service:invoke(EchoEnvelope),
    {ok, Terminal} = wait_for_status(EchoTaskId, succeeded, 100),
    ?assertEqual(
       #{<<"service-restart-echo">> => #{value => <<"served again">>}},
       maps:get(result, Terminal)),
    ?assertEqual(ReplacementPid, whereis(soma_service)).

ensure_loaded(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

tool_envelope(RequestId, Tool, Args) ->
    #{kind => invoke,
      api_version => <<"1">>,
      request_id => RequestId,
      operation =>
          #{kind => tool,
            step => #{id => RequestId, tool => Tool, args => Args}}}.

wait_for_monitored_run(_ServicePid, 0) ->
    error(service_did_not_monitor_owned_run);
wait_for_monitored_run(ServicePid, Attempts) ->
    {monitors, Monitors} = process_info(ServicePid, monitors),
    MonitoredPids = [Pid || {process, Pid} <- Monitors],
    RunPids = [Pid || {_Id, Pid, worker, [soma_run]} <-
                         supervisor:which_children(soma_run_sup),
                       is_pid(Pid)],
    case [Pid || Pid <- RunPids, lists:member(Pid, MonitoredPids)] of
        [RunPid | _] ->
            RunPid;
        [] ->
            timer:sleep(10),
            wait_for_monitored_run(ServicePid, Attempts - 1)
    end.

wait_for_replacement(_OldPid, 0) ->
    error(service_was_not_restarted);
wait_for_replacement(OldPid, Attempts) ->
    case whereis(soma_service) of
        Pid when is_pid(Pid), Pid =/= OldPid ->
            Pid;
        _ ->
            timer:sleep(10),
            wait_for_replacement(OldPid, Attempts - 1)
    end.

wait_for_status(_TaskId, _Expected, 0) ->
    error(service_task_did_not_reach_status);
wait_for_status(TaskId, Expected, Attempts) ->
    case soma_service:status(TaskId) of
        {ok, #{status := Expected} = Task} ->
            {ok, Task};
        {ok, _Task} ->
            timer:sleep(10),
            wait_for_status(TaskId, Expected, Attempts - 1)
    end.
