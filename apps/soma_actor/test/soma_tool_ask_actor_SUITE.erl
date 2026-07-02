%% @doc End-to-end proofs for the actor-owned ask_actor tool.
-module(soma_tool_ask_actor_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([ask_actor_run_step_returns_target_result_and_uses_tool_worker/1,
         ask_actor_propagates_parent_correlation_id/1,
         ask_actor_step_timeout_cancels_child_task/1,
         ask_actor_parent_cancel_cancels_child_task/1,
         ask_actor_unknown_name_fails_run_session_alive/1,
         ask_actor_dead_name_fails_run_session_alive/1]).

all() ->
    [ask_actor_run_step_returns_target_result_and_uses_tool_worker,
     ask_actor_propagates_parent_correlation_id,
     ask_actor_step_timeout_cancels_child_task,
     ask_actor_parent_cancel_cancels_child_task,
     ask_actor_unknown_name_fails_run_session_alive,
     ask_actor_dead_name_fails_run_session_alive].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(_TestCase, _Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    ok.

ask_actor_run_step_returns_target_result_and_uses_tool_worker(_Config) ->
    StorePid = event_store_pid(),
    StableName = <<"child">>,
    {ok, _ChildPid} =
        soma_actor_sup:start_actor(#{actor_id => <<"ask-actor-child">>,
                                     stable_name => StableName,
                                     event_store => StorePid,
                                     model_config => #{},
                                     tool_policy => #{}}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    ChildEnvelope =
        #{type => <<"actor.message">>,
          payload => #{},
          steps => [#{id => child_pause, tool => sleep,
                      args => #{ms => 1000}},
                    #{id => child_s1, tool => echo,
                      args => #{value => <<"ok">>}}]},
    ParentSteps =
        [#{id => s1,
           tool => ask_actor,
           timeout_ms => 5000,
           args => #{target => StableName,
                     envelope => ChildEnvelope}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, ParentSteps),

    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    ParentRunPid = run_pid_from_session(SessionPid, RunId),
    WorkerPid = tool_call_pid_from(StorePid, RunId, <<"tool.started">>),
    true = is_pid(WorkerPid),
    false = WorkerPid =:= ParentRunPid,
    case is_process_alive(WorkerPid) of
        true ->
            ok;
        false ->
            case wait_for_terminal(StorePid, RunId, 100) of
                {failed, Reason0} ->
                    ct:fail({run_failed_before_worker_observation, Reason0});
                Other0 ->
                    ct:fail({worker_not_alive, Other0})
            end
    end,

    case wait_for_terminal(StorePid, RunId, 100) of
        {completed, Events} ->
            Output = step_output(Events, s1),
            #{child_s1 := #{value := <<"ok">>}} = Output,
            ok;
        {failed, Reason} ->
            ct:fail({run_failed, Reason});
        Other ->
            ct:fail(Other)
    end.

ask_actor_propagates_parent_correlation_id(_Config) ->
    StorePid = event_store_pid(),
    StableName = <<"corr-child">>,
    ChildActorId = <<"ask-actor-corr-child">>,
    {ok, _ChildPid} =
        soma_actor_sup:start_actor(#{actor_id => ChildActorId,
                                     stable_name => StableName,
                                     event_store => StorePid,
                                     model_config => #{},
                                     tool_policy => #{}}),
    CorrelationId = <<"corr-ask-actor-parent">>,
    ParentRunId = <<"run-ask-actor-corr-parent">>,
    ChildTaskId = <<"task-ask-actor-corr-child">>,
    ChildEnvelope =
        #{type => <<"actor.message">>,
          payload => #{},
          task_id => ChildTaskId,
          steps => [#{id => child_s1, tool => echo,
                      args => #{value => <<"ok">>}}]},
    ParentSteps =
        [#{id => s1,
           tool => ask_actor,
           timeout_ms => 5000,
           args => #{target => StableName,
                     envelope => ChildEnvelope}}],
    {ok, _ParentRunPid} =
        soma_run_sup:start_run(#{run_id => ParentRunId,
                                 session_id => <<"session-ask-actor-corr">>,
                                 event_store => StorePid,
                                 correlation_id => CorrelationId,
                                 steps => ParentSteps}),

    case wait_for_terminal(StorePid, ParentRunId, 100) of
        {completed, _ParentEvents} ->
            ok;
        {failed, Reason} ->
            ct:fail({run_failed, Reason});
        Other ->
            ct:fail(Other)
    end,

    Events = soma_event_store:by_correlation(StorePid, CorrelationId),
    Types = event_types(Events),
    true = lists:member(<<"run.started">>, Types),
    true = lists:member(<<"tool.started">>, Types),
    true = lists:member(<<"run.completed">>, Types),

    ChildEvents = events_for_actor(Events, ChildActorId),
    ChildTypes = event_types(ChildEvents),
    true = lists:member(<<"actor.message.received">>, ChildTypes),
    true = lists:member(<<"actor.task.accepted">>, ChildTypes),
    true = lists:member(<<"actor.task.completed">>, ChildTypes),
    [CorrelationId] = lists:usort([maps:get(correlation_id, E) || E <- Events]),
    ok.

ask_actor_step_timeout_cancels_child_task(_Config) ->
    StorePid = event_store_pid(),
    StableName = <<"timeout-child">>,
    ChildTaskId = <<"task-ask-actor-timeout-child">>,
    {ok, TargetPid} =
        soma_actor_sup:start_actor(#{actor_id => <<"ask-actor-timeout-child">>,
                                     stable_name => StableName,
                                     event_store => StorePid,
                                     model_config => #{},
                                     tool_policy => #{}}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    ParentSteps =
        [#{id => s1,
           tool => ask_actor,
           timeout_ms => 1000,
           args => #{target => StableName,
                     envelope => long_child_envelope(ChildTaskId)}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, ParentSteps),

    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    WorkerPid = tool_call_pid_from(StorePid, RunId, <<"tool.started">>),
    ok = wait_for_task_status(TargetPid, ChildTaskId, running, 100),

    case wait_for_terminal(StorePid, RunId, 150) of
        {timeout, _Events} ->
            ok;
        Other ->
            ct:fail({expected_parent_timeout, Other})
    end,
    ok = wait_for_dead(WorkerPid, 100),
    ok = wait_for_task_status(TargetPid, ChildTaskId, cancelled, 100),
    true = is_process_alive(TargetPid),
    ok = assert_session_completes_echo(StorePid, SessionPid, after_timeout),
    ok.

ask_actor_parent_cancel_cancels_child_task(_Config) ->
    StorePid = event_store_pid(),
    StableName = <<"cancel-child">>,
    ChildTaskId = <<"task-ask-actor-cancel-child">>,
    {ok, TargetPid} =
        soma_actor_sup:start_actor(#{actor_id => <<"ask-actor-cancel-child">>,
                                     stable_name => StableName,
                                     event_store => StorePid,
                                     model_config => #{},
                                     tool_policy => #{}}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    ParentSteps =
        [#{id => s1,
           tool => ask_actor,
           timeout_ms => 60000,
           args => #{target => StableName,
                     envelope => long_child_envelope(ChildTaskId)}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, ParentSteps),

    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    ok = wait_for_task_status(TargetPid, ChildTaskId, running, 100),
    SessionPid ! {cancel_run, RunId},

    case wait_for_terminal(StorePid, RunId, 100) of
        {cancelled, _Events} ->
            ok;
        Other ->
            ct:fail({expected_parent_cancelled, Other})
    end,
    ok = wait_for_task_status(TargetPid, ChildTaskId, cancelled, 100),
    true = is_process_alive(TargetPid),
    ok = assert_session_completes_echo(StorePid, SessionPid, after_cancel),
    ok.

ask_actor_unknown_name_fails_run_session_alive(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    ParentSteps =
        [#{id => s1,
           tool => ask_actor,
           timeout_ms => 5000,
           args => #{target => <<"ghost">>,
                     envelope => short_child_envelope()}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, ParentSteps),

    case wait_for_terminal(StorePid, RunId, 100) of
        {failed, Reason} ->
            ok = assert_lookup_failed_not_found(Reason);
        Other ->
            ct:fail({expected_parent_failed, Other})
    end,
    true = is_process_alive(SessionPid),
    ok = assert_session_completes_echo(StorePid, SessionPid, after_unknown_name),
    ok.

ask_actor_dead_name_fails_run_session_alive(_Config) ->
    StorePid = event_store_pid(),
    StableName = <<"dead-child">>,
    {ok, TargetPid} =
        soma_actor_sup:start_actor(#{actor_id => <<"ask-actor-dead-child">>,
                                     stable_name => StableName,
                                     event_store => StorePid,
                                     model_config => #{},
                                     tool_policy => #{}}),
    MRef = monitor(process, TargetPid),
    exit(TargetPid, kill),
    receive
        {'DOWN', MRef, process, TargetPid, _Reason} ->
            ok
    after 2000 ->
        ct:fail(dead_actor_still_alive)
    end,

    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    ParentSteps =
        [#{id => s1,
           tool => ask_actor,
           timeout_ms => 5000,
           args => #{target => StableName,
                     envelope => short_child_envelope()}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, ParentSteps),

    case wait_for_terminal(StorePid, RunId, 100) of
        {failed, Reason} ->
            ok = assert_lookup_failed_not_found(Reason);
        Other ->
            ct:fail({expected_parent_failed, Other})
    end,
    true = is_process_alive(SessionPid),
    ok = assert_session_completes_echo(StorePid, SessionPid, after_dead_name),
    ok.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

run_pid_from_session(SessionPid, RunId) ->
    {state, _SessionId, _StorePid, Runs} = sys:get_state(SessionPid),
    #{pid := RunPid} = maps:get(RunId, Runs),
    RunPid.

wait_for_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case lists:any(fun(E) -> maps:get(event_type, E) =:= Type end, Events) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_event(StorePid, RunId, Type, N - 1)
    end.

wait_for_terminal(_StorePid, _RunId, 0) ->
    {error, timeout};
wait_for_terminal(StorePid, RunId, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case terminal(Events) of
        none ->
            timer:sleep(20),
            wait_for_terminal(StorePid, RunId, N - 1);
        Terminal ->
            Terminal
    end.

terminal(Events) ->
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(<<"run.completed">>, Types) of
        true ->
            {completed, Events};
        false ->
            case [maps:get(reason, maps:get(payload, E, #{}), undefined)
                  || E <- Events,
                     maps:get(event_type, E) =:= <<"run.failed">>] of
                [Reason | _] -> {failed, Reason};
                [] ->
                    case lists:member(<<"run.timeout">>, Types) of
                        true -> {timeout, Events};
                        false ->
                            case lists:member(<<"run.cancelled">>, Types) of
                                true -> {cancelled, Events};
                                false -> none
                            end
                    end
            end
    end.

long_child_envelope(ChildTaskId) ->
    #{type => <<"actor.message">>,
      payload => #{},
      task_id => ChildTaskId,
      steps => [#{id => child_sleep, tool => sleep, args => #{ms => 5000}}]}.

short_child_envelope() ->
    #{type => <<"actor.message">>,
      payload => #{},
      steps => [#{id => child_s1, tool => echo,
                  args => #{value => <<"unreached">>}}]}.

assert_lookup_failed_not_found(#{error := ask_actor_lookup_failed,
                                 registry_error := not_found}) ->
    ok;
assert_lookup_failed_not_found(Other) ->
    ct:fail({unexpected_lookup_failure_reason, Other}).

wait_for_task_status(_ActorPid, _TaskId, _Status, 0) ->
    {error, timeout};
wait_for_task_status(ActorPid, TaskId, Status, N) ->
    case soma_actor:get_task_status(ActorPid, TaskId) of
        #{status := Status} ->
            ok;
        _Other ->
            timer:sleep(20),
            wait_for_task_status(ActorPid, TaskId, Status, N - 1)
    end.

wait_for_dead(_Pid, 0) ->
    {error, still_alive};
wait_for_dead(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(20),
            wait_for_dead(Pid, N - 1)
    end.

assert_session_completes_echo(StorePid, SessionPid, StepId) ->
    Steps = [#{id => StepId, tool => echo,
               args => #{value => <<"session-alive">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    case wait_for_terminal(StorePid, RunId, 100) of
        {completed, Events} ->
            #{value := <<"session-alive">>} = step_output(Events, StepId),
            ok;
        Other ->
            ct:fail({expected_followup_completed, Other})
    end.

tool_call_pid_from(StorePid, RunId, EventType) ->
    [Pid | _] = [maps:get(tool_call_pid, E)
                 || E <- soma_event_store:by_run(StorePid, RunId),
                    maps:get(event_type, E) =:= EventType,
                    maps:is_key(tool_call_pid, E)],
    Pid.

step_output(Events, StepId) ->
    [E] = [Ev || Ev <- Events,
                 maps:get(event_type, Ev) =:= <<"step.succeeded">>,
                 maps:get(step_id, Ev) =:= StepId],
    maps:get(output, maps:get(payload, E)).

event_types(Events) ->
    [maps:get(event_type, E) || E <- Events].

events_for_actor(Events, ActorId) ->
    [E || E <- Events, maps:get(actor_id, E, undefined) =:= ActorId].
