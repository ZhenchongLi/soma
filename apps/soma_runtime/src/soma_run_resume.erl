%% @doc Read-only run resume reconstruction from the event trail.
-module(soma_run_resume).

-export([reconstruct/2, reconstruct/3, reconstruct_events/1,
         reconstruct_events/2]).

reconstruct(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    reconstruct_events(Events, RunId).

reconstruct(StorePid, RunId, Timeout) ->
    Events = soma_event_store:by_run(StorePid, RunId, Timeout),
    reconstruct_events(Events, RunId).

%% Reconstruct from an already-indexed run trail. Recovery owners that replay
%% the complete event log can group trails once, then reuse the same canonical
%% reconstruction without asking the store to scan its full list per run.
reconstruct_events(Events) when is_list(Events) ->
    case journaled_run(Events) of
        {ok, Steps, RunOptions} ->
            Outputs = committed_outputs(Events),
            case unknown_committed_step(Steps, Outputs) of
                {unknown, StepId} ->
                    {error, {unknown_committed_step, StepId}};
                none ->
                    case committed_outputs_are_prefix(Steps, Outputs) of
                        true ->
                            {ok, #{steps => Steps,
                                   run_options => RunOptions,
                                   outputs => Outputs,
                                   next_step => first_uncommitted_step(
                                                  Steps, Outputs),
                                   terminal_status => terminal_status(Events)}};
                        false ->
                            {error, invalid_run_started_journal}
                    end
            end;
        error ->
            {error, no_run_started_journal};
        {error, Reason} ->
            {error, Reason}
    end.

%% Store-backed reconstruction has an authoritative lookup RunId. A damaged
%% run.started payload must not redirect the resumed child to another id while
%% its CLI owner continues indexing the outer event id.
reconstruct_events(Events, ExpectedRunId) when is_list(Events) ->
    case reconstruct_events(Events) of
        {ok, #{run_options := RunOptions} = Snapshot} ->
            case maps:get(run_id, RunOptions, undefined) of
                ExpectedRunId -> {ok, Snapshot};
                _Mismatch -> {error, invalid_run_started_journal}
            end;
        {error, _} = Error ->
            Error
    end.

journaled_run([#{event_type := <<"run.started">>,
                 payload := #{steps := Steps,
                              run_options := RunOptions}} | _Rest])
  when is_list(Steps), is_map(RunOptions) ->
    case valid_journal_steps(Steps) of
        true -> {ok, Steps, RunOptions};
        false -> {error, invalid_run_started_journal}
    end;
journaled_run([_Event | Rest]) ->
    journaled_run(Rest);
journaled_run([]) ->
    error.

%% The journal is executable input after a restart, so validate the complete
%% canonical step shape before planning a resumed child.  This is deliberately
%% stricter than `soma_run''s ordinary per-step failure path: a corrupt durable
%% timeout or from_step must land one recovery failure, never start a tool and
%% then crash/retry in an event loop.
valid_journal_steps(Steps) ->
    case lists:foldl(fun validate_journal_step/2, {ok, #{}}, Steps) of
        {ok, _Seen} -> true;
        error -> false
    end.

validate_journal_step(_Step, error) ->
    error;
validate_journal_step(
  #{id := StepId, tool := Tool} = Step, {ok, Seen})
  when (is_atom(StepId) orelse is_binary(StepId)),
       (is_atom(Tool) orelse is_binary(Tool)) ->
    Args = maps:get(args, Step, #{}),
    case not maps:is_key(StepId, Seen)
         andalso is_map(Args)
         andalso valid_timeout(maps:get(timeout_ms, Step, undefined))
         andalso valid_from_step_refs(Args, Seen) of
        true -> {ok, Seen#{StepId => true}};
        false -> error
    end;
validate_journal_step(_MalformedStep, _Seen) ->
    error.

valid_timeout(undefined) -> true;
valid_timeout(TimeoutMs) ->
    is_integer(TimeoutMs) andalso TimeoutMs >= 0.

valid_from_step_refs(#{from_step := Ref}, Seen) ->
    valid_prior_ref(Ref, Seen);
valid_from_step_refs(Args, Seen) ->
    maps:fold(
      fun(_Key, {from_step, Ref}, true) -> valid_prior_ref(Ref, Seen);
         (_Key, _Value, Acc) -> Acc
      end, true, Args).

valid_prior_ref(Ref, Seen) when is_atom(Ref); is_binary(Ref) ->
    %% Match the executor's `outputs' map exactly. Atom/binary spellings that
    %% look alike are distinct Erlang map keys and must not be softened here.
    maps:is_key(Ref, Seen);
valid_prior_ref(_Ref, _Seen) ->
    false.

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

%% Sequential execution can only commit a prefix. Accepting a later committed
%% step after a gap would make `first_uncommitted_step/2' replay that later step
%% and duplicate an already-recorded effect.
committed_outputs_are_prefix(Steps, Outputs) ->
    committed_outputs_are_prefix(Steps, Outputs, committed).

committed_outputs_are_prefix([#{id := StepId} | Rest], Outputs, committed) ->
    case maps:is_key(StepId, Outputs) of
        true -> committed_outputs_are_prefix(Rest, Outputs, committed);
        false -> committed_outputs_are_prefix(Rest, Outputs, pending)
    end;
committed_outputs_are_prefix([#{id := StepId} | Rest], Outputs, pending) ->
    case maps:is_key(StepId, Outputs) of
        true -> false;
        false -> committed_outputs_are_prefix(Rest, Outputs, pending)
    end;
committed_outputs_are_prefix([], _Outputs, _Phase) ->
    true.

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
