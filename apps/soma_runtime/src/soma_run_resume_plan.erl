%% @doc Read-only resume eligibility plan over the durable trail.
%%
%% `plan/2' reconstructs the run snapshot, then classifies it into a resume
%% verdict. It starts no run and appends no events.
-module(soma_run_resume_plan).

-export([plan/2]).

plan(Events, _RunId) when is_list(Events) ->
    plan_events(Events);
plan(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    plan_events(Events).

%% Classify an already-indexed run trail. This keeps the descriptor-safety rule
%% in the runtime while allowing a durable owner to replay many runs in one
%% overall pass through the event store.
plan_events(Events) when is_list(Events) ->
    case soma_run_resume:reconstruct_events(Events) of
        {ok, Snapshot} ->
            classify(Events, Snapshot);
        {error, _} = Error ->
            Error
    end.

%% A terminal trail wins over an uncommitted next_step: a run that failed
%% mid-step leaves the step uncommitted and writes a terminal event, so this is
%% checked before next_step and never returns resume.
classify(_Events, #{terminal_status := Status})
  when Status =/= undefined ->
    {terminal, Status};
%% Every journaled step is committed and no terminal event landed, so
%% `reconstruct' found no uncommitted step: there is nothing left to resume.
classify(_Events, #{next_step := undefined}) ->
    nothing_to_do;
classify(Events, #{steps := Steps,
           run_options := RunOptions,
           outputs := Outputs,
           next_step := NextStep = #{id := NextId, tool := Tool}}) ->
    case in_flight(Events, NextId) andalso not safe_tool(Tool) of
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
in_flight(Events, StepId) ->
    lists:any(fun(#{event_type := <<"tool.started">>, step_id := Sid}) ->
                      Sid =:= StepId;
                 (_Event) ->
                      false
              end, Events).

%% Descriptor resolution stays in the plan; the pure repeat-safety rule is
%% shared through `soma_run_resume_safety'. An unresolvable tool cannot be
%% proven safe, so it is treated as unsafe.
safe_tool(Tool) ->
    case soma_tool_registry:resolve_descriptor(Tool) of
        {ok, Descriptor} ->
            soma_run_resume_safety:descriptor_safe(Descriptor);
        {error, _} ->
            false
    end.

pending_suffix(Steps, #{id := NextId}) ->
    lists:dropwhile(fun(#{id := Id}) -> Id =/= NextId end, Steps).
