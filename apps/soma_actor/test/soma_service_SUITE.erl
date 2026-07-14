-module(soma_service_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_supervised_service_restarts_and_serves_again/1]).
-export([test_single_tool_invocation_runs_without_llm_worker/1]).

all() ->
    [test_supervised_service_restarts_and_serves_again,
     test_single_tool_invocation_runs_without_llm_worker].

init_per_testcase(TestCase, Config)
  when TestCase =:= test_supervised_service_restarts_and_serves_again;
       TestCase =:= test_single_tool_invocation_runs_without_llm_worker ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo, sleep]}),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(TestCase, _Config)
  when TestCase =:= test_supervised_service_restarts_and_serves_again;
       TestCase =:= test_single_tool_invocation_runs_without_llm_worker ->
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

test_single_tool_invocation_runs_without_llm_worker(_Config) ->
    {module, soma_llm_call} = code:ensure_loaded(soma_llm_call),
    ok = start_llm_start_trace(),
    try
        RequestId = <<"service-single-tool">>,
        Args = #{value => <<"exact service output">>},
        RawEnvelope = tool_envelope(RequestId, echo, Args),
        {ok, NormalizedEnvelope} =
            soma_service_envelope:normalize(RawEnvelope),
        Step = maps:get(
                 step, maps:get(operation, NormalizedEnvelope)),

        {ok, #{task_id := TaskId, status := accepted}} =
            soma_service:invoke(NormalizedEnvelope),
        {ok, Terminal} = wait_for_status(TaskId, succeeded, 100),
        ?assertEqual(#{RequestId => Args}, maps:get(result, Terminal)),

        StorePid = runtime_event_store(),
        Events = soma_event_store:all(StorePid),
        [RunStarted] =
            [Event || Event <- Events,
                      maps:get(event_type, Event) =:= <<"run.started">>,
                      maps:get(steps, maps:get(payload, Event)) =:= [Step]],
        RunId = maps:get(run_id, RunStarted),
        RunEvents = soma_event_store:by_run(StorePid, RunId),
        ?assert(lists:any(
                  fun(Event) ->
                          maps:get(event_type, Event) =:= <<"tool.started">>
                  end,
                  RunEvents)),

        ?assertEqual([], stop_llm_start_trace())
    after
        clear_llm_start_trace()
    end.

ensure_loaded(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

start_llm_start_trace() ->
    1 = erlang:trace_pattern({soma_llm_call, start, 1}, true, [local]),
    _ = erlang:trace(all, true, [call, {tracer, self()}]),
    _ = erlang:trace(new, true, [call, {tracer, self()}]),
    ok.

stop_llm_start_trace() ->
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace(new, false, [call]),
    Ref = erlang:trace_delivered(all),
    collect_llm_start_calls(Ref, []).

collect_llm_start_calls(Ref, Calls) ->
    receive
        {trace_delivered, all, Ref} ->
            lists:reverse(Calls);
        {trace, _Pid, call, {soma_llm_call, start, Args}} ->
            collect_llm_start_calls(Ref, [Args | Calls])
    after 1000 ->
        error(llm_start_trace_not_delivered)
    end.

clear_llm_start_trace() ->
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace(new, false, [call]),
    _ = erlang:trace_pattern({soma_llm_call, start, 1}, false, [local]),
    ok.

runtime_event_store() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, StorePid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    StorePid.

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
