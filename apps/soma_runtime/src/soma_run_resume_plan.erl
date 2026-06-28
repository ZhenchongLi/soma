%% @doc Read-only resume eligibility plan over the durable trail.
%%
%% `plan/2' reconstructs the run snapshot, then classifies it into a resume
%% verdict. It starts no run and appends no events.
-module(soma_run_resume_plan).

-export([plan/2]).

plan(StorePid, RunId) ->
    case soma_run_resume:reconstruct(StorePid, RunId) of
        {ok, Snapshot} ->
            classify(StorePid, RunId, Snapshot);
        {error, _} = Error ->
            Error
    end.

%% A terminal trail wins over an uncommitted next_step: a run that failed
%% mid-step leaves the step uncommitted and writes a terminal event, so this is
%% checked before next_step and never returns resume.
classify(_StorePid, _RunId, #{terminal_status := Status})
  when Status =/= undefined ->
    {terminal, Status};
classify(StorePid, RunId,
         #{steps := Steps,
           run_options := RunOptions,
           outputs := Outputs,
           next_step := NextStep = #{id := NextId, tool := Tool}}) ->
    case in_flight(StorePid, RunId, NextId) andalso not safe_tool(Tool) of
        true ->
            {unsafe, NextId};
        false ->
            Pending = pending_suffix(Steps, NextStep),
            {resume, #{steps => Steps,
                       pending => Pending,
                       outputs => Outputs,
                       run_options => RunOptions}}
    end.

%% A `tool.started' for `next_step' means the step was mid-execution when the
%% run was interrupted.
in_flight(StorePid, RunId, StepId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    lists:any(fun(#{event_type := <<"tool.started">>, step_id := Sid}) ->
                      Sid =:= StepId;
                 (_Event) ->
                      false
              end, Events).

%% A tool is safe to re-run if it is a reader/identity effect or idempotent.
%% An unresolvable tool cannot be proven safe, so it is treated as unsafe.
safe_tool(Tool) ->
    case soma_tool_registry:resolve_descriptor(Tool) of
        {ok, #{effect := Effect, idempotent := Idempotent}} ->
            Effect =:= reader orelse Effect =:= identity orelse Idempotent =:= true;
        {ok, _Descriptor} ->
            false;
        {error, _} ->
            false
    end.

pending_suffix(Steps, #{id := NextId}) ->
    lists:dropwhile(fun(#{id := Id}) -> Id =/= NextId end, Steps).
