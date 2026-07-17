%% @doc Read-only resume eligibility plan over the durable trail.
%%
%% `plan/2' reconstructs the run snapshot, then classifies it into a resume
%% verdict. It starts no run and appends no events.
-module(soma_run_resume_plan).

-export([plan/2, plan/3]).

plan(Events, RunId) when is_list(Events) ->
    plan_events(Events, RunId, infinity);
plan(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    plan_events(Events, RunId, infinity).

plan(StorePid, RunId, Timeout)
  when is_integer(Timeout), Timeout >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Events = soma_event_store:by_run(
               StorePid, RunId, remaining_ms(Deadline)),
    plan_events(Events, RunId, {deadline, Deadline}).

%% Classify an already-indexed run trail. This keeps the descriptor-safety rule
%% in the runtime while allowing a durable owner to replay many runs in one
%% overall pass through the event store.
plan_events(Events, RunId, Timeout) when is_list(Events) ->
    case soma_run_resume:reconstruct_events(Events, RunId) of
        {ok, Snapshot} ->
            classify(Events, Snapshot, Timeout);
        {error, _} = Error ->
            Error
    end.

%% A terminal trail wins over an uncommitted next_step: a run that failed
%% mid-step leaves the step uncommitted and writes a terminal event, so this is
%% checked before next_step and never returns resume.
classify(_Events, #{terminal_status := Status}, _Timeout)
  when Status =/= undefined ->
    {terminal, Status};
%% Every journaled step is committed and no terminal event landed, so
%% `reconstruct' found no uncommitted step: there is nothing left to resume.
classify(_Events, #{next_step := undefined}, _Timeout) ->
    nothing_to_do;
classify(Events, #{steps := Steps,
           run_options := RunOptions,
           outputs := Outputs,
           next_step := NextStep = #{id := NextId, tool := Tool}}, Timeout) ->
    case in_flight(Events, NextId) of
        true ->
            case repeat_safe_descriptor(Events, NextId, Tool, Timeout) of
                {ok, Descriptor} ->
                    resume_plan(Steps, NextStep, Outputs, RunOptions,
                                #{step_id => NextId,
                                  descriptor => Descriptor});
                unsafe ->
                    {unsafe, NextId}
            end;
        false ->
            resume_plan(Steps, NextStep, Outputs, RunOptions, undefined)
    end.

resume_plan(Steps, NextStep, Outputs, RunOptions, DescriptorGuard) ->
    Pending = pending_suffix(Steps, NextStep),
    Base = #{steps => Steps,
             pending => Pending,
             outputs => Outputs,
             run_options => RunOptions},
    Plan = case DescriptorGuard of
               undefined -> Base;
               _ -> Base#{resume_descriptor_guard => DescriptorGuard}
           end,
    {resume, Plan}.

%% A `tool.started' for `next_step' means the step was mid-execution when the
%% run was interrupted.
in_flight(Events, StepId) ->
    lists:any(fun(#{event_type := <<"tool.started">>, step_id := Sid}) ->
                      Sid =:= StepId;
                 (_Event) ->
                      false
              end, Events).

%% A retry is safe only when both sides agree: every `tool.started' event for
%% the still-uncommitted step recorded a safe descriptor snapshot, and the
%% descriptor currently registered is also safe. This prevents a mutable
%% config manifest from changing state/non-idempotent -> reader/idempotent after
%% the crash and weakening the original decision.
%%
%% Journals written before the snapshot field existed fail closed for every
%% in-flight tool. A name alone cannot prove the historical descriptor: older
%% internal callers could replace even a built-in spelling through the process
%% registry API, so edge-level reserved-name checks are not durable evidence.
repeat_safe_descriptor(Events, StepId, Tool, Timeout) ->
    Starts = [Event || #{event_type := <<"tool.started">>,
                              step_id := EventStepId} = Event <- Events,
                       EventStepId =:= StepId],
    Snapshots = [Snapshot || #{payload :=
                                   #{resume_safety := Snapshot}} <- Starts],
    OriginalSafe = Starts =/= []
        andalso length(Snapshots) =:= length(Starts)
        andalso lists:all(
                  fun soma_run_resume_safety:descriptor_safe/1,
                  Snapshots),
    case OriginalSafe of
        true -> current_safe_descriptor(Tool, Timeout);
        false -> unsafe
    end.

current_safe_descriptor(Tool, Timeout)
  when is_atom(Tool); is_binary(Tool) ->
    case resolve_descriptor(Tool, Timeout) of
        {ok, Descriptor} ->
            case soma_run_resume_safety:descriptor_safe(Descriptor) of
                true -> {ok, Descriptor};
                false -> unsafe
            end;
        {error, _} ->
            unsafe
    end;
current_safe_descriptor(_MalformedToolIdentity, _Timeout) ->
    unsafe.

resolve_descriptor(Tool, infinity) ->
    soma_tool_registry:resolve_descriptor(Tool);
resolve_descriptor(Tool, {deadline, Deadline}) ->
    soma_tool_registry:resolve_descriptor(Tool, remaining_ms(Deadline)).

pending_suffix(Steps, #{id := NextId}) ->
    lists:dropwhile(fun(#{id := Id}) -> Id =/= NextId end, Steps).

remaining_ms(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
