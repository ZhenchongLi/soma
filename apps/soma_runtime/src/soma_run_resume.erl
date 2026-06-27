%% @doc Read-only run resume reconstruction from the event trail.
-module(soma_run_resume).

-export([reconstruct/2]).

reconstruct(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case journaled_run(Events) of
        {ok, Steps, RunOptions} ->
            {ok, #{steps => Steps,
                   run_options => RunOptions}};
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
