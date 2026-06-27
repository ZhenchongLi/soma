%% @doc Read-only run resume reconstruction from the event trail.
-module(soma_run_resume).

-export([reconstruct/2]).

reconstruct(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case journaled_steps(Events) of
        {ok, Steps} ->
            {ok, #{steps => Steps}};
        error ->
            {error, no_run_started_journal}
    end.

journaled_steps([#{event_type := <<"run.started">>,
                   payload := #{steps := Steps}} | _Rest])
  when is_list(Steps) ->
    {ok, Steps};
journaled_steps([_Event | Rest]) ->
    journaled_steps(Rest);
journaled_steps([]) ->
    error.
