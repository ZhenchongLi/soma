%% @doc Read-only run resume reconstruction from the event trail.
-module(soma_run_resume).

-export([reconstruct/2]).

reconstruct(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case journaled_run(Events) of
        {ok, Steps, RunOptions} ->
            Outputs = committed_outputs(Events),
            case unknown_committed_step(Steps, Outputs) of
                {unknown, StepId} ->
                    {error, {unknown_committed_step, StepId}};
                none ->
                    {ok, #{steps => Steps,
                           run_options => RunOptions,
                           outputs => Outputs,
                           next_step => first_uncommitted_step(Steps, Outputs),
                           terminal_status => terminal_status(Events)}}
            end;
        error ->
            {error, no_run_started_journal}
    end.

journaled_run([#{event_type := <<"run.started">>,
                 payload := #{steps := Steps,
                              run_options := RunOptions}} | _Rest])
  when is_list(Steps), is_map(RunOptions) ->
    {ok, Steps, RunOptions};
journaled_run([_Event | Rest]) ->
    journaled_run(Rest);
journaled_run([]) ->
    error.

committed_outputs(Events) ->
    lists:foldl(fun committed_output/2, #{}, Events).

committed_output(#{event_type := <<"step.succeeded">>,
                   step_id := StepId,
                   payload := #{output := Output}}, Acc) ->
    Acc#{StepId => Output};
committed_output(_Event, Acc) ->
    Acc.

unknown_committed_step(Steps, Outputs) ->
    JournaledIds = [StepId || #{id := StepId} <- Steps],
    Committed = maps:keys(Outputs),
    case [StepId || StepId <- Committed,
                    not lists:member(StepId, JournaledIds)] of
        [StepId | _] -> {unknown, StepId};
        [] -> none
    end.

first_uncommitted_step([Step = #{id := StepId} | Rest], Outputs) ->
    case maps:is_key(StepId, Outputs) of
        true -> first_uncommitted_step(Rest, Outputs);
        false -> Step
    end;
first_uncommitted_step([], _Outputs) ->
    undefined.

terminal_status(Events) ->
    lists:foldl(fun terminal_status/2, undefined, Events).

terminal_status(#{event_type := <<"run.completed">>}, _Acc) -> completed;
terminal_status(#{event_type := <<"run.failed">>}, _Acc) -> failed;
terminal_status(#{event_type := <<"run.timeout">>}, _Acc) -> timeout;
terminal_status(#{event_type := <<"run.cancelled">>}, _Acc) -> cancelled;
terminal_status(_Event, Acc) -> Acc.
