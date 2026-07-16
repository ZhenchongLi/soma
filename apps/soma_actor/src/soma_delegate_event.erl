%% @doc The sole public-event boundary for delegated task lifecycle data.
%% Delegate producers pass lifecycle state through this module; only the
%% bounded allowlist below can reach the generic event store.
-module(soma_delegate_event).

-define(MAX_BYTES, 4096).

-export([append/5, max_bytes/0, reason_class/1]).

-spec max_bytes() -> pos_integer().
max_bytes() ->
    ?MAX_BYTES.

-spec append(binary(), binary(), binary(), non_neg_integer(), map()) -> ok.
append(EventType, TaskId, CorrelationId, Round, Outcome)
  when is_binary(EventType), is_binary(TaskId),
       is_binary(CorrelationId), is_integer(Round), Round >= 0,
       is_map(Outcome) ->
    Payload = scrub_term(outcome_payload(EventType, Outcome)),
    Event0 = complete_event(
               EventType, TaskId, CorrelationId, Round, Payload),
    Event = fit_event(Event0),
    soma_event_store:append(event_store_pid(), Event).

complete_event(EventType, TaskId, CorrelationId, Round, Payload) ->
    #{event_id => mint_event_id(),
      timestamp => erlang:system_time(nanosecond),
      session_id => undefined,
      run_id => undefined,
      step_id => undefined,
      tool_call_id => undefined,
      event_type => EventType,
      payload => Payload,
      task_id => TaskId,
      correlation_id => CorrelationId,
      round => Round}.

outcome_payload(EventType, Outcome) ->
    Base = #{phase => event_phase(EventType)},
    WithStatus = maybe_put(status, outcome_status(Outcome), Base),
    WithReason =
        maybe_put(reason_class, outcome_reason_class(Outcome), WithStatus),
    WithUsage =
        maybe_put(usage_count, usage_count(Outcome), WithReason),
    WithMutations =
        maybe_put(mutation_count, mutation_count(Outcome), WithUsage),
    maybe_put(
      unknown_outcome_count, unknown_outcome_count(Outcome),
      WithMutations).

event_phase(<<"delegate.task.accepted">>) -> accepted;
event_phase(<<"delegate.task.running">>) -> running;
event_phase(<<"delegate.round.started">>) -> round_started;
event_phase(<<"delegate.round.completed">>) -> round_completed;
event_phase(<<"delegate.task.cancel_requested">>) -> cancel_requested;
event_phase(<<"delegate.task.cleanup">>) -> cleanup;
event_phase(<<"delegate.task.terminal">>) -> terminal.

outcome_status(Outcome) ->
    normalize_status(
      nested_value(status, terminal_result, Outcome)).

normalize_status(Status)
  when Status =:= accepted; Status =:= running;
       Status =:= succeeded; Status =:= failed;
       Status =:= rejected;
       Status =:= timeout; Status =:= cancelled;
       Status =:= in_doubt ->
    Status;
normalize_status(_Status) ->
    undefined.

outcome_reason_class(Outcome) ->
    reason_class(
      nested_value(reason, terminal_result, Outcome)).

-spec reason_class(term()) -> atom() | undefined.
reason_class(undefined) -> undefined;
reason_class(#{reason_class := ReasonClass}) ->
    reason_class(ReasonClass);
reason_class({ReasonClass, _Detail}) ->
    reason_class(ReasonClass);
reason_class(failed) -> failed;
reason_class(coordinator_crashed) -> coordinator_crashed;
reason_class(round_worker_crashed) -> round_worker_crashed;
reason_class(round_timeout) -> round_timeout;
reason_class(unsafe_result_lost) -> unsafe_result_lost;
reason_class(invalid_round_sequence) -> invalid_round_sequence;
reason_class(snapshot_too_large) -> snapshot_too_large;
reason_class(round_worker_start_failed) -> round_worker_start_failed;
reason_class(lease_acquisition_failed) -> lease_acquisition_failed;
reason_class(invalid_llm) -> invalid_llm;
reason_class(invalid_action_steps) -> invalid_action_steps;
reason_class(llm_call_crashed) -> llm_call_crashed;
reason_class(llm_start_failed) -> llm_start_failed;
reason_class(run_start_failed) -> run_start_failed;
reason_class(_PrivateOrUnknownReason) -> failed.

usage_count(Outcome) ->
    case maps:get(usage_count, Outcome, undefined) of
        Count when is_integer(Count), Count >= 0 ->
            Count;
        _NotAnExplicitCount ->
            case maps:get(usage, Outcome, undefined) of
                Usage when is_map(Usage) -> maps:size(Usage);
                _NoUsage -> undefined
            end
    end.

mutation_count(Outcome) ->
    ledger_or_delta_count(
      mutation_count, mutation_ledger, mutation, Outcome).

unknown_outcome_count(Outcome) ->
    ledger_or_delta_count(
      unknown_outcome_count, unknown_outcome_ledger,
      unknown_outcome, Outcome).

ledger_or_delta_count(CountKey, LedgerKey, DeltaKey, Outcome) ->
    case maps:get(CountKey, Outcome, undefined) of
        Count when is_integer(Count), Count >= 0 ->
            Count;
        _NotAnExplicitCount ->
            case maps:get(LedgerKey, Outcome, undefined) of
                Ledger when is_list(Ledger) -> length(Ledger);
                _NoLedger ->
                    case maps:is_key(DeltaKey, Outcome) of
                        true -> 1;
                        false -> undefined
                    end
            end
    end.

nested_value(Key, ContainerKey, Outcome) ->
    case maps:get(Key, Outcome, undefined) of
        undefined ->
            case maps:get(ContainerKey, Outcome, undefined) of
                Nested when is_map(Nested) ->
                    maps:get(Key, Nested, undefined);
                _NoNestedOutcome ->
                    undefined
            end;
        Value ->
            Value
    end.

maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    maps:put(Key, Value, Map).

%% The event schema is already an allowlist. Recursively scrub the values that
%% survive it as a second boundary, so no process-local term can be serialized
%% even if a future bounded lifecycle field becomes structured.
scrub_term(Term)
  when is_pid(Term); is_port(Term); is_reference(Term);
       is_function(Term) ->
    redacted;
scrub_term(secret_value) ->
    redacted;
scrub_term(<<"secret_value">>) ->
    redacted;
scrub_term(Term) when is_map(Term) ->
    maps:fold(
      fun(Key, Value, Acc) ->
              maps:put(scrub_term(Key), scrub_term(Value), Acc)
      end,
      #{}, Term);
scrub_term([]) ->
    [];
scrub_term([Head | Tail]) ->
    [scrub_term(Head) | scrub_term(Tail)];
scrub_term(Term) when is_tuple(Term) ->
    list_to_tuple(
      [scrub_term(Element) || Element <- tuple_to_list(Term)]);
scrub_term(Term) ->
    Term.

fit_event(Event) ->
    EventBytes = encoded_bytes(Event),
    case EventBytes =< ?MAX_BYTES of
        true ->
            Event;
        false ->
            Fallback =
                Event#{payload =>
                           fallback_payload(
                             maps:get(payload, Event), EventBytes)},
            true = encoded_bytes(Fallback) =< ?MAX_BYTES,
            Fallback
    end.

fallback_payload(Payload, OriginalBytes) ->
    Summary =
        maps:with(
          [phase, status, usage_count, mutation_count,
           unknown_outcome_count],
          Payload),
    Summary#{truncated => true, original_bytes => OriginalBytes}.

encoded_bytes(Term) ->
    byte_size(term_to_binary(Term, [deterministic])).

mint_event_id() ->
    Suffix =
        integer_to_binary(
          erlang:unique_integer([positive, monotonic])),
    <<"delegate-event-", Suffix/binary>>.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
