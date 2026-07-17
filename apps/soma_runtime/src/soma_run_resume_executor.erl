%% @doc Resume executor: turns a resume plan into a running `soma_run' child.
%%
%% `resume/3' plans the durable trail (read-only via `soma_run_resume_plan'),
%% and on a `{resume, _}' verdict starts a fresh `soma_run' child under
%% `soma_run_sup' that continues from the not-yet-committed suffix. The new run
%% is a distinct process from the interrupted original: the original is gone, so
%% resume means a new attempt over the same `run_id', seeded with the committed
%% outputs and the pending steps the plan reconstructed.
%%
%% On an `{unsafe, _}' verdict -- a run interrupted mid-execution of a
%% non-idempotent `state' tool, where re-running could double an external effect
%% -- resume is fail-safe: it lands the run as failed (appends `run.failed') and
%% starts no `soma_run' child.
-module(soma_run_resume_executor).

-export([resume/3, resume/4]).

resume(RunId, Owner, Store) ->
    resume_plan(soma_run_resume_plan:plan(Store, RunId),
                RunId, Owner, Store, infinity).

resume(RunId, Owner, Store, Timeout)
  when is_integer(Timeout), Timeout >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    resume_plan(
      soma_run_resume_plan:plan(Store, RunId, remaining_ms(Deadline)),
      RunId, Owner, Store, {deadline, Deadline}).

resume_plan(Plan, RunId, Owner, Store, Timeout) ->
    case Plan of
        {resume, #{steps := Steps,
                   pending := Pending,
                   outputs := Outputs,
                   run_options := RunOptions} = ResumePlan} ->
            %% `RunId' is the authoritative outer event/index identity. The
            %% planner has already checked the journal copy matches it; never
            %% let damaged run_options redirect a child to another id.
            Opts0 = #{run_id => RunId,
                      session_id => maps:get(session_id, RunOptions, undefined),
                      correlation_id => maps:get(correlation_id, RunOptions, undefined),
                      event_store => Store,
                      session_pid => Owner,
                      steps => Steps,
                      pending => Pending,
                      outputs => Outputs,
                      %% Do not execute a resumed step until this caller has
                      %% observed the supervisor acknowledgement. A timed-out
                      %% but committed start stays paused for later adoption.
                      start_paused => true},
            Opts = case maps:find(resume_descriptor_guard, ResumePlan) of
                       {ok, Guard} ->
                           Opts0#{resume_descriptor_guard => Guard};
                       error -> Opts0
                   end,
            case start_run(Opts, Timeout) of
                {ok, RunPid} = Started ->
                    case safe_activate_run(RunPid, Timeout) of
                        ok -> Started;
                        {error, Reason} ->
                            {error, {resume_start_failed, Reason}}
                    end;
                {error, Reason} -> {error, {resume_start_failed, Reason}}
            end;
        {unsafe, StepId} ->
            append_event(
              Store, unsafe_failed_event(Store, RunId, StepId, Timeout),
              Timeout),
            {error, {resume_unsafe, StepId}};
        %% A terminal event is already on the trail (a run that finished, or one a
        %% prior unsafe resume already landed as failed): start no run, append no
        %% event, return the terminal verdict. This is what makes a repeated unsafe
        %% resume idempotent -- the trail remembers the terminal, so the second
        %% call classifies {terminal, _} before it ever looks at next_step.
        {terminal, Status} ->
            {terminal, Status};
        %% Every journal step already committed step.succeeded, but no terminal
        %% event landed: there is no pending suffix to continue. Start no run,
        %% append no event, return nothing_to_do.
        nothing_to_do ->
            nothing_to_do;
        %% The trail has no usable journal (no run.started), or commits a step the
        %% journal never declared: there is nothing to reconstruct from. Start no
        %% run, append no event, propagate the error to the caller unchanged.
        {error, Reason} ->
            {error, Reason}
    end.

unsafe_failed_event(Store, RunId, StepId, Timeout) ->
    Base = #{run_id => RunId,
             step_id => StepId,
             event_type => <<"run.failed">>,
             payload => #{reason => {resume_unsafe, StepId}}},
    Reconstructed = case Timeout of
                        infinity ->
                            soma_run_resume:reconstruct(Store, RunId);
                        {deadline, Deadline} ->
                            soma_run_resume:reconstruct(
                              Store, RunId, remaining_ms(Deadline))
                    end,
    case Reconstructed of
        {ok, #{run_options := RunOptions}} ->
            with_optional(correlation_id,
                          maps:get(correlation_id, RunOptions, undefined),
                          with_optional(session_id,
                                        maps:get(session_id, RunOptions, undefined),
                                        Base));
        {error, _} ->
            Base
    end.

with_optional(_Key, undefined, Acc) ->
    Acc;
with_optional(Key, Value, Acc) ->
    Acc#{Key => Value}.

append_event(Store, Event, infinity) ->
    soma_event_store:append(Store, Event);
append_event(Store, Event, {deadline, Deadline}) ->
    soma_event_store:append(Store, Event, remaining_ms(Deadline)).

start_run(Opts, infinity) ->
    soma_run_sup:start_run(Opts);
start_run(Opts, {deadline, Deadline}) ->
    soma_run_sup:start_run(Opts, remaining_ms(Deadline)).

activate_run(RunPid, infinity) ->
    soma_run:activate_sync(RunPid, infinity, infinity);
activate_run(RunPid, {deadline, Deadline}) ->
    soma_run:activate_sync(RunPid, Deadline, remaining_ms(Deadline)).

safe_activate_run(RunPid, Timeout) ->
    try activate_run(RunPid, Timeout) of
        Result -> Result
    catch
        exit:Reason -> {error, {activation_unresponsive, Reason}}
    end.

remaining_ms(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
