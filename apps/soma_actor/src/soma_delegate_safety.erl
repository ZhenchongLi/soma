%% @doc Derive delegated state-mutation facts from the runtime event trail.
%% Candidate identities are allocated before a run so owner loss can retain
%% them, but only a matching `tool.started' event admits one to a safety ledger.
-module(soma_delegate_safety).

-export([facts/3, unknown_facts/2]).

facts(Invocations, Round, EventStorePid)
  when is_list(Invocations), is_integer(Round), Round >= 0,
       is_pid(EventStorePid) ->
    EventsByRun = events_by_run(Invocations, EventStorePid),
    lists:foldl(
      fun(Invocation, Acc) ->
              add_invocation_fact(
                Invocation, Round, EventsByRun, Acc)
      end,
      #{mutations => [], unknown_outcomes => []},
      Invocations);
facts(_InvalidInvocations, _InvalidRound, _EventStorePid) ->
    #{mutations => [], unknown_outcomes => []}.

%% Legacy prepared-round seams report dispatch through the coordinator
%% protocol and have no runtime event trail to inspect. Keep that compatibility
%% boundary explicit instead of weakening facts/3 for adaptive runtime rounds.
unknown_facts(Invocations, Round)
  when is_list(Invocations), is_integer(Round), Round >= 0 ->
    lists:foldl(
      fun(Invocation, Acc) ->
              add_unknown_fact(Invocation, Round, Acc)
      end,
      #{mutations => [], unknown_outcomes => []},
      Invocations);
unknown_facts(_InvalidInvocations, _InvalidRound) ->
    #{mutations => [], unknown_outcomes => []}.

events_by_run(Invocations, EventStorePid) ->
    RunIds =
        lists:usort(
          [RunId
           || #{run_id := RunId} <- Invocations,
              is_binary(RunId)]),
    maps:from_list(
      [{RunId, soma_event_store:by_run(EventStorePid, RunId)}
       || RunId <- RunIds]).

add_invocation_fact(
  Invocation = #{run_id := RunId, step_id := StepId},
  Round, EventsByRun,
  Acc = #{mutations := Mutations,
          unknown_outcomes := UnknownOutcomes}) ->
    Events = maps:get(RunId, EventsByRun, []),
    case started_tool_call(StepId, Events) of
        {ok, ToolCallId} ->
            Outcome = terminal_outcome(StepId, ToolCallId, Events),
            Mutation = Invocation#{round => Round, outcome => Outcome},
            case Outcome of
                unknown ->
                    UnknownOutcome =
                        #{round => Round,
                          invocation => Invocation,
                          outcome => unknown},
                    Acc#{mutations := Mutations ++ [Mutation],
                         unknown_outcomes :=
                             UnknownOutcomes ++ [UnknownOutcome]};
                _KnownOutcome ->
                    Acc#{mutations := Mutations ++ [Mutation]}
            end;
        not_started ->
            Acc
    end;
add_invocation_fact(_InvalidInvocation, _Round, _EventsByRun, Acc) ->
    Acc.

add_unknown_fact(
  Invocation, Round,
  Acc = #{mutations := Mutations,
          unknown_outcomes := UnknownOutcomes})
  when is_map(Invocation) ->
    Mutation = Invocation#{round => Round, outcome => unknown},
    UnknownOutcome =
        #{round => Round,
          invocation => Invocation,
          outcome => unknown},
    Acc#{mutations := Mutations ++ [Mutation],
         unknown_outcomes := UnknownOutcomes ++ [UnknownOutcome]};
add_unknown_fact(_InvalidInvocation, _Round, Acc) ->
    Acc.

started_tool_call(StepId, Events) ->
    case [ToolCallId
          || #{event_type := <<"tool.started">>,
               step_id := ActualStepId,
               tool_call_id := ToolCallId} <- Events,
             ActualStepId =:= StepId,
             is_binary(ToolCallId)] of
        [ToolCallId | _Remaining] -> {ok, ToolCallId};
        [] -> not_started
    end.

terminal_outcome(StepId, ToolCallId, Events) ->
    case has_event(<<"tool.succeeded">>, StepId, ToolCallId, Events) of
        true ->
            succeeded;
        false ->
            terminal_failure_outcome(StepId, ToolCallId, Events)
    end.

terminal_failure_outcome(StepId, ToolCallId, Events) ->
    case has_event(<<"tool.failed">>, StepId, ToolCallId, Events) of
        true ->
            failed;
        false ->
            terminal_run_outcome(StepId, ToolCallId, Events)
    end.

terminal_run_outcome(StepId, ToolCallId, Events) ->
    case has_event(<<"run.timeout">>, StepId, ToolCallId, Events) of
        true -> timeout;
        false -> unknown
    end.

has_event(EventType, StepId, ToolCallId, Events) ->
    lists:any(
      fun(#{event_type := ActualType,
            step_id := ActualStepId,
            tool_call_id := ActualToolCallId}) ->
              ActualType =:= EventType andalso
                  ActualStepId =:= StepId andalso
                  ActualToolCallId =:= ToolCallId;
         (_OtherEvent) ->
              false
      end,
      Events).
