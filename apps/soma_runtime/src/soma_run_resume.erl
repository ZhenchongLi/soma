%% @doc Read-only run resume reconstruction from the event trail.
-module(soma_run_resume).

-export([reconstruct/2]).

reconstruct(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case journaled_run(Events) of
        {ok, Steps, RunOptions} ->
            Outputs = committed_outputs(Events),
            {ok, #{steps => Steps,
                   run_options => RunOptions,
                   outputs => Outputs,
                   next_step => first_uncommitted_step(Steps, Outputs)}};
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

first_uncommitted_step([Step = #{id := StepId} | Rest], Outputs) ->
    case maps:is_key(StepId, Outputs) of
        true -> first_uncommitted_step(Rest, Outputs);
        false -> Step
    end;
first_uncommitted_step([], _Outputs) ->
    undefined.
