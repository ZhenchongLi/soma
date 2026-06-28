%% @doc Read-only resume eligibility plan over the durable trail.
%%
%% `plan/2' reconstructs the run snapshot, then classifies it into a resume
%% verdict. It starts no run and appends no events.
-module(soma_run_resume_plan).

-export([plan/2]).

plan(StorePid, RunId) ->
    case soma_run_resume:reconstruct(StorePid, RunId) of
        {ok, Snapshot} ->
            classify(Snapshot);
        {error, _} = Error ->
            Error
    end.

classify(#{steps := Steps,
           run_options := RunOptions,
           outputs := Outputs,
           next_step := NextStep}) ->
    Pending = pending_suffix(Steps, NextStep),
    {resume, #{steps => Steps,
               pending => Pending,
               outputs => Outputs,
               run_options => RunOptions}}.

pending_suffix(Steps, #{id := NextId}) ->
    lists:dropwhile(fun(#{id := Id}) -> Id =/= NextId end, Steps).
