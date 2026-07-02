%% @doc End-to-end proofs for the actor-owned ask_actor tool.
-module(soma_tool_ask_actor_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([ask_actor_run_step_returns_target_result_and_uses_tool_worker/1]).

all() ->
    [ask_actor_run_step_returns_target_result_and_uses_tool_worker].

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
                        false -> none
                    end
            end
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
