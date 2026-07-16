%% @doc One temporary delegated-task owner. It starts inert so the ingress can
%% install its request route and monitor before allowing task work to begin.
-module(soma_delegate_coordinator).

-behaviour(gen_statem).

-define(DEFAULT_ROUND_TIMEOUT_MS, 120000).
-define(ROUND_FORCED_STOP_MS, 1000).
-define(MAX_TIMER_MS, 16#ffffffff).
-define(MAX_ROUND_SNAPSHOT_BYTES, 65536).
-define(MAX_ROUND_RESULT_BYTES, 16384).
-define(DEFAULT_RECENT_ROUND_WINDOW, 4).

-export([start_link/1, status/1, cancel/2]).
-export([init/1, callback_mode/0, handle_event/4]).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

status(CoordinatorPid) when is_pid(CoordinatorPid) ->
    gen_statem:call(CoordinatorPid, status).

cancel(CoordinatorPid, TaskId) when is_pid(CoordinatorPid) ->
    gen_statem:cast(CoordinatorPid, {cancel, TaskId}).

init(#{request := Request = #{request_id := RequestId,
                             correlation_id := CorrelationId},
       task_id := TaskId,
       ingress_pid := IngressPid,
       budget_limits := BudgetLimits,
       runtime_options := RuntimeOptions})
  when is_binary(RequestId), is_binary(TaskId), is_binary(CorrelationId),
       is_pid(IngressPid), is_map(BudgetLimits), is_map(RuntimeOptions) ->
    Budgets = maps:get(budgets, Request, #{}),
    RoundSequence = maps:get(round_sequence, RuntimeOptions, []),
    TaskDeadlineTimer = arm_task_deadline(BudgetLimits, TaskId),
    Data = #{request_id => RequestId,
             task_id => TaskId,
             correlation_id => CorrelationId,
             ingress_pid => IngressPid,
             request => Request,
             tool_policy => configured_tool_policy(RuntimeOptions),
             status => accepted,
             objective => maps:get(objective, Request, undefined),
             output_contract => maps:get(output_contract, Request, undefined),
             context_checkpoint => initial_checkpoint(RuntimeOptions),
             budgets => Budgets,
             budget_limits => BudgetLimits,
             usage => #{},
             counters => initial_counters(),
             mutation_ledger => [],
             unknown_outcome_ledger => [],
             idempotency_state => #{},
             adaptive_events => adaptive_round_sequence(RoundSequence),
             recent_round_data => undefined,
             task_summary => #{},
             recent_rounds => [],
             task_artifacts => [],
             scoped_leases =>
                 #{requests =>
                       maps:get(lease_requests, RuntimeOptions, []),
                   handles => #{},
                   guard => undefined},
             next_round_id => 1,
             active_round => undefined,
             task_deadline_timer => TaskDeadlineTimer,
             task_deadline_expired => false,
             cleanup_started => false,
             terminal_result => undefined,
             continuation_round_entry => undefined,
             round_sequence => RoundSequence},
    {ok, awaiting_start, Data}.

callback_mode() ->
    handle_event_function.

handle_event(info, {delegate_begin, TaskId}, awaiting_start,
             Data = #{task_id := TaskId}) ->
    RunningData = Data#{status := running},
    ok = emit_delegate_event(
           <<"delegate.task.running">>, 0, RunningData, RunningData),
    checkpoint_ingress(RunningData),
    begin_task(RunningData);
handle_event({call, From}, status, _StateName, Data) ->
    {keep_state, Data,
     [{reply, From, {ok, public_projection(Data)}}]};
handle_event(
  info,
  {delegate_reserve_budget,
   TaskId, RoundId, WorkerPid, WorkerIdentity, ResultCapability,
   Counter, Units},
  running,
  Data = #{task_id := TaskId,
           active_round :=
               #{round_id := RoundId,
                 worker_pid := WorkerPid,
                 worker_identity := WorkerIdentity,
                 result_capability := ResultCapability}})
  when (Counter =:= llm_calls orelse Counter =:= tool_calls),
       is_integer(Units), Units >= 0 ->
    {Reply, UpdatedData} =
        case reserve_child_counter(Counter, Units, Data) of
            {ok, ReservedData} ->
                {ok, ReservedData};
            {error, Limit} ->
                {{error, {budget_exceeded, Limit}}, Data}
        end,
    checkpoint_ingress(UpdatedData),
    WorkerPid !
        {delegate_budget_reserved,
         TaskId, RoundId, WorkerIdentity, ResultCapability,
         Counter, Reply},
    {keep_state, UpdatedData};
handle_event(info,
             {delegate_status, TaskId, ReplyTo, StatusRef},
             _StateName,
             Data = #{task_id := TaskId})
  when is_pid(ReplyTo), is_reference(StatusRef) ->
    ReplyTo !
        {delegate_status_reply, TaskId, self(), StatusRef,
         {ok, public_projection(Data)}},
    {keep_state, Data};
handle_event(info,
             {timeout, TaskDeadlineTimer,
              {delegate_task_deadline, TaskId}},
             StateName,
             Data = #{task_id := TaskId,
                      task_deadline_timer := TaskDeadlineTimer})
  when StateName =:= awaiting_start; StateName =:= running ->
    expire_task_deadline(Data);
handle_event(cast, {cancel, TaskId}, running,
             Data = #{task_id := TaskId,
                      active_round := ActiveRound})
  when is_map(ActiveRound) ->
    ok = emit_delegate_event(
           <<"delegate.task.cancel_requested">>, 0, Data, Data),
    cancel_active_round(cancelled, Data);
handle_event(cast, {cancel, TaskId}, StateName,
             Data = #{task_id := TaskId})
  when StateName =:= awaiting_start; StateName =:= running ->
    ok = emit_delegate_event(
           <<"delegate.task.cancel_requested">>, 0, Data, Data),
    start_cleanup(#{status => cancelled}, Data);
handle_event(internal, finish_cleanup, cleaning,
             Data = #{ingress_pid := IngressPid,
                      task_id := TaskId,
                      cleanup_started := true,
                      terminal_result := Projection}) ->
    ok = release_scoped_leases(Data),
    ok = emit_delegate_event(
           <<"delegate.task.terminal">>, 0, Data, Data),
    IngressPid ! {delegate_terminal, TaskId, self(), Projection},
    {next_state, awaiting_terminal_store, Data};
handle_event(info, {delegate_terminal_stored, TaskId},
             awaiting_terminal_store,
             Data = #{task_id := TaskId}) ->
    {stop, normal, Data};
handle_event(info,
             {delegate_provider_usage,
              TaskId, RoundId, WorkerPid, WorkerIdentity,
              ResultCapability, Usage},
             running,
             Data = #{task_id := TaskId,
                      active_round :=
                          ActiveRound =
                              #{round_id := RoundId,
                                worker_pid := WorkerPid,
                                worker_identity := WorkerIdentity,
                                result_capability := ResultCapability}})
  when is_map(Usage) ->
    %% Provider-authenticated usage becomes task-owned the moment the
    %% LLM call completes: losing the round worker during the action
    %% phase can no longer revert task totals to the estimate.
    CommittedData = commit_usage(Usage, Data),
    UpdatedRound = ActiveRound#{usage_committed => true},
    {keep_state, CommittedData#{active_round := UpdatedRound}};
handle_event(info,
             {delegate_state_action_dispatched,
              TaskId, RoundId, WorkerPid, WorkerIdentity,
              ResultCapability, StateInvocationData,
              UnsafeInvocationData},
             running,
             Data = #{task_id := TaskId,
                      active_round :=
                          ActiveRound =
                              #{round_id := RoundId,
                                worker_pid := WorkerPid,
                                worker_identity := WorkerIdentity,
                                result_capability := ResultCapability,
                                unsafe_action_dispatched := false}})
  when is_list(StateInvocationData),
       is_list(UnsafeInvocationData) ->
    StateInvocations =
        normalize_unsafe_invocations(StateInvocationData),
    UnsafeInvocations =
        normalize_unsafe_invocations(UnsafeInvocationData),
    case StateInvocations of
        [] ->
            {keep_state, Data};
        [_StateInvocation | _] ->
            MarkedRound =
                ActiveRound#{state_invocations := StateInvocations,
                             unsafe_action_dispatched :=
                                 UnsafeInvocations =/= [],
                             unsafe_invocations := UnsafeInvocations,
                             unsafe_invocation :=
                                 first_invocation(UnsafeInvocations)},
            MarkedData = Data#{active_round := MarkedRound},
            checkpoint_ingress(MarkedData),
            WorkerPid !
                {delegate_state_action_recorded,
                 TaskId, RoundId, WorkerIdentity, ResultCapability,
                 StateInvocations, UnsafeInvocations},
            {keep_state, MarkedData}
    end;
handle_event(info,
             {delegate_unsafe_action_dispatched,
              TaskId, RoundId, WorkerPid, WorkerIdentity,
              ResultCapability, UnsafeInvocationData},
             running,
             Data = #{task_id := TaskId,
                      active_round :=
                          ActiveRound =
                              #{round_id := RoundId,
                                worker_pid := WorkerPid,
                                worker_identity := WorkerIdentity,
                                result_capability := ResultCapability,
                                unsafe_action_dispatched := false}})
  when is_map(UnsafeInvocationData); is_list(UnsafeInvocationData) ->
    case normalize_unsafe_invocations(UnsafeInvocationData) of
        [] ->
            {keep_state, Data};
        UnsafeInvocations ->
            MarkedRound =
                ActiveRound#{unsafe_action_dispatched := true,
                             state_invocations := UnsafeInvocations,
                             unsafe_invocations := UnsafeInvocations,
                             unsafe_invocation :=
                                 hd(UnsafeInvocations)},
            MarkedData = Data#{active_round := MarkedRound},
            checkpoint_ingress(MarkedData),
            WorkerPid !
                {delegate_unsafe_action_recorded,
                 TaskId, RoundId, WorkerIdentity, ResultCapability,
                 UnsafeInvocations},
            {keep_state, MarkedData}
    end;
handle_event(info,
             {delegate_round_result, TaskId, RoundId, WorkerPid,
              WorkerIdentity, ResultCapability, Result},
             running,
             Data = #{task_id := TaskId,
                      active_round :=
                          #{round_id := RoundId,
                            worker_pid := WorkerPid,
                            worker_mref := _WorkerMRef,
                            worker_identity := WorkerIdentity,
                            result_capability := ResultCapability}}) ->
    commit_round_result(Result, RoundId, Data);
handle_event(info,
             {'DOWN', WorkerMRef, process, WorkerPid, _Reason},
             running,
             Data = #{active_round :=
                          ActiveRound = #{round_id := RoundId,
                            worker_pid := WorkerPid,
                            worker_mref := WorkerMRef}}) ->
    cancel_round_timers(ActiveRound),
    handle_round_worker_down(ActiveRound, RoundId, Data);
handle_event(info,
             {'DOWN', GuardMRef, process, GuardPid, Reason},
             _StateName,
             Data = #{scoped_leases :=
                          ScopedLeases = #{guard := GuardPid,
                                           guard_mref := GuardMRef}}) ->
    %% The lease guard died under the coordinator: its handles are stale
    %% and its raw leases are lost, so the task fails here at the
    %% ownership boundary — never a wedged `running` task or a `noproc`
    %% crash inside a later cleanup.
    ClearedLeases = ScopedLeases#{guard := undefined,
                                  guard_mref := undefined},
    Data1 = Data#{scoped_leases := ClearedLeases},
    Data2 =
        case maps:get(active_round, Data1, undefined) of
            undefined ->
                Data1;
            ActiveRound = #{worker_pid := WorkerPid,
                            worker_mref := WorkerMRef} ->
                cancel_round_timers(ActiveRound),
                _ = erlang:demonitor(WorkerMRef, [flush]),
                _ = supervisor:terminate_child(
                      soma_delegate_round_sup, WorkerPid),
                Data1#{active_round := undefined}
        end,
    start_cleanup(
      #{status => failed, reason => {lease_guard_lost, Reason}}, Data2);
handle_event(info,
             {timeout, RoundTimer,
              {delegate_round_timeout, TaskId, RoundId, WorkerPid,
               WorkerIdentity, ResultCapability}},
             running,
             Data = #{task_id := TaskId,
                      active_round :=
                          #{round_id := RoundId,
                            worker_pid := WorkerPid,
                            worker_identity := WorkerIdentity,
                            result_capability := ResultCapability,
                            round_timer := RoundTimer}}) ->
    cancel_active_round(timeout, Data);
handle_event(info,
             {timeout, ForcedStopTimer,
              {delegate_round_forced_stop, TaskId, RoundId, WorkerPid,
               WorkerIdentity, ResultCapability}},
             running,
             Data = #{task_id := TaskId,
                      active_round :=
                          ActiveRound =
                              #{round_id := RoundId,
                                worker_pid := WorkerPid,
                                worker_identity := WorkerIdentity,
                                result_capability := ResultCapability,
                                forced_stop_timer := ForcedStopTimer,
                                cancel_status := CancelStatus}})
  when CancelStatus =:= timeout; CancelStatus =:= cancelled ->
    _ = supervisor:terminate_child(
          soma_delegate_round_sup, WorkerPid),
    {keep_state,
     Data#{active_round :=
               ActiveRound#{forced_stop_timer := undefined}}};
handle_event(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.

begin_task(Data = #{round_sequence := []}) ->
    {next_state, running, Data};
begin_task(Data = #{round_sequence := [_Round | _Remaining]}) ->
    case acquire_scoped_leases(Data) of
        {ok, LeaseData} ->
            start_round(LeaseData);
        {error, Reason, LeaseData} ->
            fail_before_round(LeaseData, Reason)
    end;
begin_task(Data) ->
    fail_before_round(Data, invalid_round_sequence).

start_round(Data) ->
    case counter_available(rounds, 1, Data) of
        true ->
            start_available_round(Data);
        false ->
            start_cleanup(budget_projection(max_rounds), Data)
    end.

start_available_round(
  Data = #{round_sequence := [RoundEntry | Remaining],
           task_id := TaskId,
           correlation_id := CorrelationId,
           next_round_id := RoundId}) ->
    start_available_round_entry(
      RoundEntry, Remaining, TaskId, CorrelationId, RoundId, Data);
start_available_round(
  Data = #{round_sequence := [],
           continuation_round_entry := RoundEntry,
           task_id := TaskId,
           correlation_id := CorrelationId,
           next_round_id := RoundId})
  when RoundEntry =/= undefined ->
    start_available_round_entry(
      RoundEntry, [], TaskId, CorrelationId, RoundId, Data);
start_available_round(Data) ->
    fail_before_round(Data, invalid_round_sequence).

start_available_round_entry(
  RoundEntry, Remaining, TaskId, CorrelationId, RoundId, Data) ->
    case round_snapshot(Data) of
        {ok, Snapshot} ->
            prepare_and_start_round(
              RoundEntry, Remaining, Snapshot, TaskId,
              CorrelationId, RoundId,
              Data#{continuation_round_entry := RoundEntry});
        {error, Reason} ->
            fail_before_round(Data, Reason)
    end.

prepare_and_start_round(
  RoundEntry, Remaining, Snapshot, TaskId, CorrelationId, RoundId, Data) ->
    case prepare_round_work(RoundEntry, Snapshot) of
        {ok, Work} ->
            AdaptiveData = enable_adaptive_events(Work, Data),
            PromptProjection =
                soma_delegate_prompt:project(
                  Snapshot, prompt_data(AdaptiveData)),
            Budgets = maps:get(budget_limits, AdaptiveData),
            CommittedPromptTokens =
                maps:get(
                  prompt_tokens, maps:get(counters, AdaptiveData), 0),
            case soma_delegate_prompt:preflight(
                   PromptProjection, Budgets, CommittedPromptTokens) of
                {ok, PromptCall} ->
                    PromptedWork =
                        attach_prompt(
                          Work, PromptProjection, PromptCall, Budgets),
                    start_round_worker(
                      PromptedWork, Remaining, Snapshot, TaskId,
                      CorrelationId, RoundId, AdaptiveData);
                {error, context_budget_exceeded} ->
                    start_cleanup(
                      context_budget_projection(), AdaptiveData)
            end;
        {error, invalid_round_sequence} ->
            fail_before_round(Data, invalid_round_sequence)
    end.

attach_prompt(
  Work = #{llm := Llm}, PromptProjection,
  #{messages := Messages,
    estimated_prompt_tokens := EstimatedPromptTokens},
  Budgets)
  when is_map(Llm) ->
    AccountedPromptTokens =
        accounted_prompt_tokens(EstimatedPromptTokens, Budgets),
    Work#{prompt_tokens_estimate => AccountedPromptTokens,
          llm :=
              Llm#{prompt_projection => PromptProjection,
                   messages => Messages,
                   retain_usage => true}};
attach_prompt(Work, _PromptProjection, _PromptCall, _Budgets) ->
    Work.

prompt_data(Data = #{tool_policy := ToolPolicy,
                     request := Request}) ->
    CapabilityScope =
        maps:get(capability_scope, Request, #{tools => []}),
    ToolSchemas =
        soma_delegate_capability:tool_schemas(
          soma_tool_registry:catalog(),
          #{tool_policy => ToolPolicy,
            capability_scope => CapabilityScope}),
    Data#{tool_schemas => ToolSchemas}.

start_round_worker(
  Work, Remaining, Snapshot, TaskId, CorrelationId, RoundId, Data) ->
    WorkerIdentity = mint_worker_identity(RoundId),
    ResultCapability = make_ref(),
    WorkerOpts = #{coordinator_pid => self(),
                   task_id => TaskId,
                   correlation_id => CorrelationId,
                   round_id => RoundId,
                   worker_identity => WorkerIdentity,
                   result_capability => ResultCapability,
                   tool_policy => maps:get(tool_policy, Data),
                   capability_scope =>
                       maps:get(
                         capability_scope,
                         maps:get(request, Data),
                         #{tools => []}),
                   snapshot => Snapshot,
                   work => Work},
    case soma_delegate_round_sup:start_round(WorkerOpts) of
        {ok, WorkerPid} ->
            WorkerMRef = erlang:monitor(process, WorkerPid),
            RoundTimer = arm_round_timer(
                           Work, TaskId, RoundId, WorkerPid,
                           WorkerIdentity, ResultCapability),
            ActiveRound = #{round_id => RoundId,
                            worker_identity => WorkerIdentity,
                            worker_pid => WorkerPid,
                            worker_mref => WorkerMRef,
                            result_capability => ResultCapability,
                            round_timer => RoundTimer,
                            forced_stop_timer => undefined,
                            cancel_status => undefined,
                            prompt_tokens_estimate =>
                                maps:get(prompt_tokens_estimate, Work, 0),
                            prompt_tokens_reserved => 0,
                            unsafe_action_dispatched => false,
                            state_invocations => [],
                            unsafe_invocation => undefined,
                            unsafe_invocations => []},
            CountedData = consume_counter(rounds, 1, Data),
            StartedData = CountedData#{round_sequence := Remaining,
                                       next_round_id := RoundId + 1,
                                       active_round := ActiveRound},
            ok = emit_delegate_event(
                   <<"delegate.round.started">>, RoundId,
                   StartedData, StartedData),
            checkpoint_ingress(StartedData),
            WorkerPid !
                {delegate_round_begin, TaskId, RoundId, WorkerIdentity,
                 ResultCapability},
            {next_state, running, StartedData};
        {error, _Reason} ->
            fail_before_round(Data, round_worker_start_failed)
    end.

fail_before_round(Data, Reason) ->
    start_cleanup(#{status => failed, reason => Reason}, Data).

commit_round_result(Result, RoundId, Data) ->
    case valid_round_result(Result) of
        true ->
            ActiveRound = maps:get(active_round, Data),
            commit_finished_round(Result, RoundId, ActiveRound, Data);
        false ->
            {keep_state, Data}
    end.

commit_finished_round(Result, RoundId, ActiveRound, Data) ->
    SafetyFacts = active_safety_facts(ActiveRound, RoundId, Data),
    UnsafeUnresolved =
        maps:get(unknown_outcomes, SafetyFacts, []) =/= [],
    commit_finished_round(
      Result, RoundId, ActiveRound, UnsafeUnresolved,
      SafetyFacts, Data).

commit_finished_round(
  _Result, RoundId,
  ActiveRound = #{cancel_status := timeout}, false, SafetyFacts,
  Data = #{task_deadline_expired := true}) ->
    Projection = task_deadline_projection(RoundId),
    LedgeredData = commit_safety_facts(SafetyFacts, Data),
    ClearedData =
        clear_committed_round(
          Projection, RoundId, ActiveRound, LedgeredData),
    start_cleanup(Projection, ClearedData);
commit_finished_round(
  _Result, RoundId,
  ActiveRound = #{cancel_status := timeout}, false, SafetyFacts, Data) ->
    Failure = round_timeout_failure(RoundId),
    LedgeredData = commit_safety_facts(SafetyFacts, Data),
    ClearedData =
        clear_committed_round(
          Failure, RoundId, ActiveRound, LedgeredData),
    continue_after_pre_stateful_failure(
      Failure, ClearedData);
commit_finished_round(
  _Result, RoundId,
  ActiveRound = #{cancel_status := timeout}, true, SafetyFacts, Data) ->
    %% The deadline decision is sticky. A late result from dispatched
    %% non-idempotent work can no longer succeed: the mutation happened,
    %% so the honest terminal is in_doubt with the invocation on the
    %% ledgers — never a post-deadline success.
    Projection = #{status => in_doubt,
                   reason => deadline_after_unsafe_dispatch,
                   round => RoundId},
    LedgeredData = commit_safety_facts(SafetyFacts, Data),
    ClearedData =
        clear_committed_round(
          Projection, RoundId, ActiveRound,
          LedgeredData#{recent_round_data := Projection}),
    start_cleanup(Projection, ClearedData);
commit_finished_round(
  Result, RoundId,
  ActiveRound = #{cancel_status := cancelled},
  _UnsafeDispatched, _SafetyFacts, Data) ->
    CommittedData = commit_round_deltas(Result, Data),
    Status = cancelled_round_status(Result),
    Projection = #{status => Status, round => RoundId},
    ClearedData =
        clear_committed_round(
          Projection, RoundId, ActiveRound, CommittedData),
    start_cleanup(Projection, ClearedData);
commit_finished_round(
  Result, RoundId, ActiveRound,
  _UnsafeDispatched, _SafetyFacts, Data) ->
    CommittedData = commit_round_deltas(Result, Data),
    ClearedData =
        clear_committed_round(
          Result, RoundId, ActiveRound, CommittedData),
    advance_after_round(Result, RoundId, ClearedData).

clear_committed_round(
  EventOutcome, RoundId,
  ActiveRound = #{worker_pid := WorkerPid,
                  worker_mref := WorkerMRef},
  CommittedData) ->
    cancel_round_timers(ActiveRound),
    _ = erlang:demonitor(WorkerMRef, [flush]),
    _ = supervisor:terminate_child(
          soma_delegate_round_sup, WorkerPid),
    ClearedData = CommittedData#{active_round := undefined},
    ok = emit_round_completed(
           RoundId, EventOutcome, ClearedData),
    checkpoint_ingress(ClearedData),
    ClearedData.

commit_round_deltas(Result, Data = #{active_round := ActiveRound}) ->
    RoundId = maps:get(round_id, ActiveRound),
    ObservationData =
        commit_action_observation(Result, RoundId, Data),
    CheckpointData =
        case maps:find(checkpoint, Result) of
            {ok, Checkpoint} ->
                ObservationData#{context_checkpoint := Checkpoint};
            error ->
                ObservationData
        end,
    UsageData =
        case {maps:find(usage, Result), round_usage_committed(Data)} of
            {{ok, Usage}, false} when is_map(Usage) ->
                commit_usage(Usage, CheckpointData);
            _CommittedOrMissing ->
                %% Usage was already committed at LLM completion (or the
                %% result carries none); committing again would double
                %% count the round.
                CheckpointData
        end,
    MutationData =
        case maps:find(mutations, Result) of
            {ok, Mutations} when is_list(Mutations) ->
                commit_mutations(Mutations, UsageData);
            _MissingOrInvalidMutations ->
                case maps:find(mutation, Result) of
                    {ok, Mutation} ->
                        commit_mutation(Mutation, UsageData);
                    error ->
                        UsageData
                end
        end,
    UnknownOutcomeData =
        case maps:find(unknown_outcomes, Result) of
            {ok, UnknownOutcomes} when is_list(UnknownOutcomes) ->
                commit_unknown_outcomes(
                  UnknownOutcomes, MutationData);
            _MissingOrInvalidUnknownOutcomes ->
                case maps:find(unknown_outcome, Result) of
                    {ok, UnknownOutcome} ->
                        commit_unknown_outcome(
                          UnknownOutcome, MutationData);
                    error ->
                        MutationData
                end
        end,
    TerminalData =
        case maps:find(terminal_result, Result) of
            {ok, TerminalResult} ->
                UnknownOutcomeData#{terminal_result := TerminalResult};
            error ->
                UnknownOutcomeData
        end,
    case maps:get(adaptive_event, Result, false) of
        true -> TerminalData#{adaptive_events := true};
        false -> TerminalData
    end.

commit_mutation(Mutation,
                Data = #{mutation_ledger := MutationLedger}) ->
    update_idempotency_state(
      Mutation,
      Data#{mutation_ledger := MutationLedger ++ [Mutation]}).

commit_mutations(Mutations, Data) ->
    lists:foldl(
      fun(Mutation, Acc) -> commit_mutation(Mutation, Acc) end,
      Data, Mutations).

commit_unknown_outcome(
  UnknownOutcome,
  Data = #{unknown_outcome_ledger := UnknownOutcomeLedger}) ->
    IdempotencyDelta =
        case maps:get(invocation, UnknownOutcome, undefined) of
            Invocation when is_map(Invocation) ->
                maps:merge(
                  Invocation, maps:remove(invocation, UnknownOutcome));
            _MissingInvocation ->
                UnknownOutcome
        end,
    update_idempotency_state(
      IdempotencyDelta,
      Data#{unknown_outcome_ledger :=
                UnknownOutcomeLedger ++ [UnknownOutcome]}).

commit_unknown_outcomes(UnknownOutcomes, Data) ->
    lists:foldl(
      fun(UnknownOutcome, Acc) ->
              commit_unknown_outcome(UnknownOutcome, Acc)
      end,
      Data, UnknownOutcomes).

update_idempotency_state(
  Delta, Data = #{idempotency_state := IdempotencyState}) ->
    case invocation_key(Delta) of
        {ok, InvocationKey} ->
            Previous = maps:get(InvocationKey, IdempotencyState, #{}),
            Updated = maps:merge(Previous, Delta),
            Data#{idempotency_state :=
                      maps:put(
                        InvocationKey, Updated, IdempotencyState)};
        error ->
            Data
    end.

invocation_key(#{invocation_id := InvocationId}) ->
    {ok, InvocationId};
invocation_key(#{run_id := RunId}) ->
    {ok, RunId};
invocation_key(_UnidentifiedDelta) ->
    error.

round_usage_committed(#{active_round := #{usage_committed := true}}) ->
    true;
round_usage_committed(_Data) ->
    false.

commit_usage(Usage, Data) ->
    UsageData = Data#{usage := Usage},
    case maps:get(prompt_tokens, Usage, undefined) of
        ReportedPromptTokens
          when is_integer(ReportedPromptTokens),
               ReportedPromptTokens >= 0 ->
            replace_prompt_estimate(ReportedPromptTokens, UsageData);
        _MissingOrInvalidPromptUsage ->
            UsageData
    end.

replace_prompt_estimate(
  ReportedPromptTokens,
  Data = #{active_round := ActiveRound,
           counters := Counters}) ->
    ReservedPromptTokens =
        maps:get(prompt_tokens_reserved, ActiveRound, 0),
    CurrentPromptTokens = maps:get(prompt_tokens, Counters, 0),
    RetainedPromptTokens =
        CurrentPromptTokens - min(CurrentPromptTokens, ReservedPromptTokens),
    CorrectedCounters =
        Counters#{prompt_tokens :=
                      RetainedPromptTokens + ReportedPromptTokens},
    Data#{counters := CorrectedCounters}.

commit_action_observation(
  Result = #{status := Status,
    phase := action,
    decision := continue,
    terminal_result := Observation},
  RoundId,
  Data = #{recent_rounds := RecentRounds,
           task_summary := TaskSummary,
           budget_limits := Budgets}) ->
    ArtifactData = commit_action_artifact(Result, Data),
    ObservationRef = action_observation_ref(Observation),
    RunId = maps:get(run_id, Result, undefined),
    ToolCallIds = action_tool_call_ids(RunId),
    RecentRound = #{round => RoundId,
                    status => Status,
                    observation => Observation},
    RecentRoundData =
        case maps:find(artifact_excerpt, Result) of
            {ok, ArtifactExcerpt} when is_map(ArtifactExcerpt) ->
                RecentRound#{artifact_excerpt => ArtifactExcerpt};
            _NoArtifactExcerpt ->
                RecentRound
        end,
    {EvictedRounds, RetainedRounds} =
        retain_recent_rounds(
          RecentRounds ++ [RecentRoundData],
          recent_round_window(Budgets)),
    UpdatedSummary =
        merge_evicted_rounds(EvictedRounds, TaskSummary),
    CommittedData =
        ArtifactData#{recent_round_data := RecentRound,
                      task_summary := UpdatedSummary,
                      recent_rounds := RetainedRounds},
    ok = emit_delegate_event(
           <<"delegate.action.completed">>, RoundId,
           #{status => Status,
             run_id => RunId,
             tool_call_ids => ToolCallIds,
             observation_ref => ObservationRef},
           CommittedData),
    CommittedData;
commit_action_observation(_Result, _RoundId, Data) ->
    Data.

commit_action_artifact(
  #{artifact := Artifact, artifact_excerpt := ArtifactExcerpt},
  Data = #{task_artifacts := TaskArtifacts})
  when is_map(Artifact), is_map(ArtifactExcerpt) ->
    Data#{task_artifacts := TaskArtifacts ++ [Artifact]};
commit_action_artifact(_Result, Data) ->
    Data.

action_observation_ref(#{handle := Handle}) when is_binary(Handle) ->
    #{handle => Handle};
action_observation_ref(_InlineObservation) ->
    #{inline => true}.

recent_round_window(Budgets) ->
    case maps:get(
           recent_round_window, Budgets,
           ?DEFAULT_RECENT_ROUND_WINDOW) of
        Window when is_integer(Window), Window >= 0 ->
            Window;
        _InvalidWindow ->
            ?DEFAULT_RECENT_ROUND_WINDOW
    end.

retain_recent_rounds(Rounds, Window) ->
    EvictedCount = max(length(Rounds) - Window, 0),
    lists:split(EvictedCount, Rounds).

merge_evicted_rounds([], Summary) ->
    Summary;
merge_evicted_rounds(
  [#{round := Round,
     status := Status,
     observation := Observation} | Remaining],
  EmptySummary)
  when map_size(EmptySummary) =:= 0 ->
    Summary =
        #{action => tool_observation,
          status => Status,
          counts => #{rounds => 1, Status => 1},
          first_round => Round,
          last_round => Round,
          observation_ref => action_observation_ref(Observation)},
    merge_evicted_rounds(Remaining, Summary);
merge_evicted_rounds(
  [#{round := Round,
     status := Status,
     observation := Observation} | Remaining],
  Summary = #{status := PreviousStatus,
              counts := Counts}) ->
    UpdatedCounts =
        Counts#{rounds := maps:get(rounds, Counts) + 1,
                Status => maps:get(Status, Counts, 0) + 1},
    UpdatedSummary =
        Summary#{status := merged_summary_status(PreviousStatus, Status),
                 counts := UpdatedCounts,
                 last_round := Round,
                 observation_ref :=
                     action_observation_ref(Observation)},
    merge_evicted_rounds(Remaining, UpdatedSummary).

merged_summary_status(Status, Status) ->
    Status;
merged_summary_status(_PreviousStatus, _Status) ->
    mixed.

advance_after_round(
  #{status := Status, phase := action, decision := continue,
    adaptive_event := true}, _RoundId, Data)
  when Status =:= succeeded; Status =:= failed; Status =:= timeout ->
    start_round(Data);
advance_after_round(
  #{status := succeeded, decision := continue}, _RoundId,
  Data = #{round_sequence := [_NextWork | _Remaining]}) ->
    begin_task(Data);
advance_after_round(
  #{status := Status, phase := action, decision := continue}, _RoundId,
  Data = #{round_sequence := [_NextWork | _Remaining]})
  when Status =:= failed; Status =:= timeout ->
    begin_task(Data);
advance_after_round(Result, RoundId, Data) ->
    Projection = round_projection(Result, RoundId),
    start_cleanup(Projection, Data).

cancel_active_round(
  Status,
  Data = #{task_id := TaskId,
           active_round :=
               ActiveRound = #{round_id := RoundId,
                               worker_pid := WorkerPid,
                               worker_identity := WorkerIdentity,
                               result_capability := ResultCapability}}) ->
    cancel_timer(maps:get(round_timer, ActiveRound, undefined)),
    WorkerPid !
        {delegate_round_cancel, TaskId, RoundId, WorkerIdentity,
         ResultCapability, Status},
    ForcedStopTimer =
        arm_forced_stop_timer(
          Status, TaskId, RoundId, WorkerPid,
          WorkerIdentity, ResultCapability),
    UpdatedRound = ActiveRound#{round_timer := undefined,
                                forced_stop_timer := ForcedStopTimer,
                                cancel_status := Status},
    {keep_state, Data#{active_round := UpdatedRound}}.

handle_round_worker_down(
  ActiveRound, RoundId,
  Data = #{task_deadline_expired := true}) ->
    SafetyFacts = active_safety_facts(ActiveRound, RoundId, Data),
    case maps:get(unknown_outcomes, SafetyFacts, []) of
        [_Unknown | _] ->
            finish_lost_unsafe_result(
              SafetyFacts, RoundId, Data);
        [] ->
            Projection = task_deadline_projection(RoundId),
            ok = emit_round_completed(RoundId, Projection, Data),
            finish_worker_down(
              Projection, commit_safety_facts(SafetyFacts, Data))
    end;
handle_round_worker_down(ActiveRound, RoundId, Data) ->
    SafetyFacts = active_safety_facts(ActiveRound, RoundId, Data),
    case maps:get(unknown_outcomes, SafetyFacts, []) of
        [_Unknown | _] ->
            finish_lost_unsafe_result(
              SafetyFacts, RoundId, Data);
        [] ->
            handle_resolved_round_worker_down(
              ActiveRound, RoundId,
              commit_safety_facts(SafetyFacts, Data))
    end.

handle_resolved_round_worker_down(ActiveRound, RoundId, Data) ->
    case maps:get(cancel_status, ActiveRound, undefined) of
        cancelled ->
            Projection = worker_down_projection(ActiveRound, RoundId),
            ok = emit_round_completed(RoundId, Projection, Data),
            finish_worker_down(Projection, Data);
        undefined ->
            Failure = round_worker_crash_failure(RoundId),
            ok = emit_round_completed(RoundId, Failure, Data),
            continue_after_pre_stateful_failure(
              Failure, Data#{active_round := undefined});
        timeout ->
            Failure = round_timeout_failure(RoundId),
            ok = emit_round_completed(RoundId, Failure, Data),
            continue_after_pre_stateful_failure(
              Failure, Data#{active_round := undefined});
        _OtherWorkerLoss ->
            Projection = worker_down_projection(ActiveRound, RoundId),
            ok = emit_round_completed(RoundId, Projection, Data),
            finish_worker_down(Projection, Data)
    end.

finish_lost_unsafe_result(SafetyFacts, RoundId, Data) ->
    Projection = #{status => in_doubt,
                   reason => unsafe_result_lost,
                   round => RoundId},
    ok = emit_round_completed(RoundId, Projection, Data),
    finish_worker_down(
      Projection,
      (commit_safety_facts(SafetyFacts, Data))#{
           recent_round_data := Projection}).

commit_safety_facts(
  #{mutations := Mutations, unknown_outcomes := UnknownOutcomes},
  Data) ->
    commit_unknown_outcomes(
      UnknownOutcomes, commit_mutations(Mutations, Data)).

active_safety_facts(ActiveRound, RoundId, Data) ->
    StateInvocations = active_state_invocations(ActiveRound),
    UnsafeInvocations = active_unsafe_invocations(ActiveRound),
    case maps:get(adaptive_events, Data, false) of
        true ->
            soma_delegate_safety:facts(
              StateInvocations, UnsafeInvocations,
              RoundId, event_store_pid());
        false ->
            soma_delegate_safety:unknown_facts(
              StateInvocations, UnsafeInvocations, RoundId)
    end.

active_state_invocations(ActiveRound) ->
    case maps:get(state_invocations, ActiveRound, []) of
        [_StateInvocation | _] = StateInvocations ->
            StateInvocations;
        [] ->
            active_unsafe_invocations(ActiveRound)
    end.

active_unsafe_invocations(ActiveRound) ->
    case maps:get(unsafe_invocations, ActiveRound, []) of
        [_Unsafe | _] = UnsafeInvocations ->
            UnsafeInvocations;
        [] ->
            normalize_unsafe_invocations(
              maps:get(unsafe_invocation, ActiveRound, undefined))
    end.

normalize_unsafe_invocations(Invocation) when is_map(Invocation) ->
    [Invocation];
normalize_unsafe_invocations(Invocations) when is_list(Invocations) ->
    [Invocation || Invocation <- Invocations, is_map(Invocation)];
normalize_unsafe_invocations(_InvalidInvocationData) ->
    [].

first_invocation([Invocation | _Remaining]) ->
    Invocation;
first_invocation([]) ->
    undefined.

finish_worker_down(Projection, Data) ->
    start_cleanup(Projection, Data#{active_round := undefined}).

continue_after_pre_stateful_failure(
  Failure, Data = #{round_sequence := [_NextRound | _Remaining]}) ->
    begin_task(
      Data#{status := running,
            recent_round_data := Failure});
continue_after_pre_stateful_failure(Failure, Data) ->
    start_cleanup(Failure, Data#{recent_round_data := Failure}).

start_cleanup(Projection0, Data = #{cleanup_started := false}) ->
    Projection = terminal_projection(Projection0, Data),
    Status = maps:get(status, Projection),
    DeadlineClearedData = cancel_task_deadline(Data),
    CleanupData0 = DeadlineClearedData#{status := Status,
                                        cleanup_started := true,
                                        terminal_result := Projection},
    CleanupData = terminal_event_data(Projection0, CleanupData0),
    checkpoint_ingress(CleanupData),
    ok = emit_delegate_event(
           <<"delegate.task.cleanup">>, 0,
           CleanupData, CleanupData),
    {next_state, cleaning,
     CleanupData,
     [{next_event, internal, finish_cleanup}]};
start_cleanup(_Projection, Data = #{cleanup_started := true}) ->
    {keep_state, Data}.

round_worker_crash_failure(RoundId) ->
    #{status => failed,
      reason => round_worker_crashed,
      round => RoundId}.

round_timeout_failure(RoundId) ->
    #{status => timeout,
      reason => round_timeout,
      round => RoundId}.

task_deadline_projection(RoundId) ->
    #{status => timeout, round => RoundId}.

worker_down_projection(ActiveRound, RoundId) ->
    case maps:get(cancel_status, ActiveRound, undefined) of
        cancelled ->
            #{status => cancelled, round => RoundId};
        timeout ->
            #{status => timeout, round => RoundId};
        undefined ->
            #{status => failed,
              reason => round_worker_crashed,
              round => RoundId}
    end.

arm_round_timer(Work, TaskId, RoundId, WorkerPid,
                WorkerIdentity, ResultCapability) ->
    TimeoutMs = timeout_ms(
                  maps:get(round_timeout_ms, Work, undefined),
                  ?DEFAULT_ROUND_TIMEOUT_MS),
    erlang:start_timer(
      TimeoutMs, self(),
      {delegate_round_timeout, TaskId, RoundId, WorkerPid,
       WorkerIdentity, ResultCapability}).

arm_task_deadline(Budgets, TaskId) when is_map(Budgets) ->
    case maps:get(deadline_ms, Budgets, undefined) of
        DeadlineMs when is_integer(DeadlineMs),
                        DeadlineMs > 0,
                        DeadlineMs =< ?MAX_TIMER_MS ->
            erlang:start_timer(
              DeadlineMs, self(),
              {delegate_task_deadline, TaskId});
        _MissingOrInvalidDeadline ->
            undefined
    end;
arm_task_deadline(_InvalidBudgets, _TaskId) ->
    undefined.

expire_task_deadline(Data = #{active_round := ActiveRound})
  when is_map(ActiveRound) ->
    DeadlineData =
        Data#{task_deadline_timer := undefined,
              task_deadline_expired := true},
    cancel_active_round(timeout, DeadlineData);
expire_task_deadline(Data) ->
    DeadlineData =
        Data#{task_deadline_timer := undefined,
              task_deadline_expired := true},
    start_cleanup(#{status => timeout}, DeadlineData).

cancel_task_deadline(
  Data = #{task_deadline_timer := TaskDeadlineTimer}) ->
    cancel_timer(TaskDeadlineTimer),
    Data#{task_deadline_timer := undefined}.

arm_forced_stop_timer(
  Status, TaskId, RoundId, WorkerPid,
  WorkerIdentity, ResultCapability) ->
    case Status of
        timeout ->
            start_forced_stop_timer(
              TaskId, RoundId, WorkerPid,
              WorkerIdentity, ResultCapability);
        cancelled ->
            start_forced_stop_timer(
              TaskId, RoundId, WorkerPid,
              WorkerIdentity, ResultCapability)
    end.

start_forced_stop_timer(
  TaskId, RoundId, WorkerPid,
  WorkerIdentity, ResultCapability) ->
    erlang:start_timer(
      ?ROUND_FORCED_STOP_MS, self(),
      {delegate_round_forced_stop, TaskId, RoundId, WorkerPid,
       WorkerIdentity, ResultCapability}).

timeout_ms(TimeoutMs, _Default)
  when is_integer(TimeoutMs), TimeoutMs > 0 ->
    TimeoutMs;
timeout_ms(_InvalidOrMissing, Default) ->
    Default.

cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) when is_reference(TimerRef) ->
    _ = erlang:cancel_timer(
          TimerRef, [{async, false}, {info, false}]),
    ok.

cancel_round_timers(ActiveRound) ->
    cancel_timer(maps:get(round_timer, ActiveRound, undefined)),
    cancel_timer(maps:get(forced_stop_timer, ActiveRound, undefined)).

valid_round_result(Result) when is_map(Result) ->
    byte_size(term_to_binary(Result, [deterministic])) =<
        ?MAX_ROUND_RESULT_BYTES andalso
        valid_round_result_keys(Result) andalso
        valid_result_status(Result) andalso
        valid_optional_enum(
          phase, Result, [decision, llm, action]) andalso
        valid_optional_enum(
          decision, Result, [continue, terminal]) andalso
        valid_optional_boolean(adaptive_event, Result) andalso
        valid_optional_binary(run_id, Result) andalso
        valid_optional_result_term(checkpoint, Result) andalso
        valid_optional_result_map(usage, Result) andalso
        valid_optional_result_map(mutation, Result) andalso
        valid_optional_result_list(mutations, Result) andalso
        valid_optional_result_map(unknown_outcome, Result) andalso
        valid_optional_result_list(unknown_outcomes, Result) andalso
        valid_optional_result_map(artifact, Result) andalso
        valid_optional_result_map(artifact_excerpt, Result) andalso
        valid_optional_result_map(terminal_result, Result);
valid_round_result(_Result) ->
    false.

valid_round_result_keys(Result) ->
    Allowed =
        [status, phase, decision, reason, checkpoint, usage,
         mutation, mutations, unknown_outcome, unknown_outcomes,
         artifact, artifact_excerpt,
         terminal_result, adaptive_event, run_id],
    lists:all(
      fun(Key) -> lists:member(Key, Allowed) end,
      maps:keys(Result)).

valid_result_status(Result) ->
    lists:member(
      maps:get(status, Result, invalid),
      [succeeded, failed, rejected, timeout, cancelled]).

valid_optional_enum(Key, Result, Allowed) ->
    case maps:find(Key, Result) of
        {ok, Value} -> lists:member(Value, Allowed);
        error -> true
    end.

valid_optional_result_map(Key, Result) ->
    case maps:find(Key, Result) of
        {ok, Value} when is_map(Value) ->
            soma_delegate_task_data:safe_term(Value);
        {ok, _InvalidValue} ->
            false;
        error ->
            true
    end.

valid_optional_result_list(Key, Result) ->
    case maps:find(Key, Result) of
        {ok, Value} when is_list(Value) ->
            soma_delegate_task_data:safe_term(Value);
        {ok, _InvalidValue} ->
            false;
        error ->
            true
    end.

valid_optional_result_term(Key, Result) ->
    case maps:find(Key, Result) of
        {ok, Value} ->
            soma_delegate_task_data:safe_term(Value);
        error ->
            true
    end.

valid_optional_boolean(Key, Result) ->
    case maps:find(Key, Result) of
        {ok, Value} when is_boolean(Value) -> true;
        {ok, _InvalidValue} -> false;
        error -> true
    end.

valid_optional_binary(Key, Result) ->
    case maps:find(Key, Result) of
        {ok, Value} when is_binary(Value) -> true;
        {ok, _InvalidValue} -> false;
        error -> true
    end.

cancelled_round_status(#{unknown_outcomes := [_Unknown | _]}) ->
    in_doubt;
cancelled_round_status(_Result) ->
    cancelled.

round_projection(
  #{unknown_outcomes := [_Unknown | _]}, RoundId) ->
    #{status => in_doubt,
      reason => unsafe_result_lost,
      round => RoundId};
round_projection(
  #{status := succeeded,
    decision := terminal,
    terminal_result := TerminalResult},
  RoundId) ->
    maps:merge(
      #{status => succeeded, round => RoundId},
      maps:with([result], TerminalResult));
round_projection(
  #{status := failed,
    reason := {budget_exceeded, Limit}},
  RoundId) ->
    (budget_projection(Limit))#{round => RoundId};
round_projection(#{status := succeeded}, RoundId) ->
    #{status => succeeded, round => RoundId};
round_projection(#{status := Status} = Result, RoundId) ->
    Base = #{status => Status, round => RoundId},
    case maps:get(reason, Result, undefined) of
        undefined -> Base;
        Reason ->
            Base#{reason => soma_delegate_event:reason_class(Reason)}
    end.

mint_worker_identity(RoundId) ->
    Round = integer_to_binary(RoundId),
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<"delegate-round-", Round/binary, "-", Suffix/binary>>.

round_snapshot(Data = #{scoped_leases := #{handles := Handles}}) ->
    Snapshot =
        (maps:with(
           [task_id, correlation_id, objective, output_contract,
            context_checkpoint, budgets, usage, mutation_ledger,
            unknown_outcome_ledger],
           Data))#{resource_handles => Handles},
    case soma_delegate_task_data:valid_snapshot(Snapshot) of
        true ->
            case byte_size(term_to_binary(Snapshot, [deterministic])) =<
                     ?MAX_ROUND_SNAPSHOT_BYTES of
                true -> {ok, Snapshot};
                false -> {error, snapshot_too_large}
            end;
        false ->
            {error, invalid_task_state}
    end.

prepare_round_work(Work, _Snapshot) when is_map(Work) ->
    {ok, Work};
prepare_round_work(Prepare, Snapshot) when is_function(Prepare, 1) ->
    case Prepare(Snapshot) of
        Work when is_map(Work) ->
            {ok, Work};
        _InvalidWork ->
            {error, invalid_round_sequence}
    end;
prepare_round_work(_InvalidEntry, _Snapshot) ->
    {error, invalid_round_sequence}.

acquire_scoped_leases(
  Data = #{scoped_leases := #{guard := GuardPid}})
  when is_pid(GuardPid) ->
    {ok, Data};
acquire_scoped_leases(
  Data = #{scoped_leases := #{requests := []}}) ->
    {ok, Data};
acquire_scoped_leases(
  Data = #{task_id := TaskId,
           scoped_leases := ScopedLeases = #{requests := Requests}}) ->
    GuardOpts = #{coordinator_pid => self(),
                  task_id => TaskId,
                  lease_requests => Requests},
    case soma_delegate_lease_sup:start_guard(GuardOpts) of
        {ok, GuardPid} ->
            %% The coordinator owns the guard: monitor it so a guard death
            %% fails the task at the ownership boundary instead of leaving
            %% stale handles active behind a running task.
            GuardMRef = erlang:monitor(process, GuardPid),
            Handles = soma_delegate_lease_guard:handles(GuardPid),
            UpdatedLeases = ScopedLeases#{requests := [],
                                          handles := Handles,
                                          guard := GuardPid,
                                          guard_mref => GuardMRef},
            {ok, Data#{scoped_leases := UpdatedLeases}};
        {error, _Reason} ->
            {error, lease_acquisition_failed, Data}
    end.

release_scoped_leases(
  #{scoped_leases := ScopedLeases = #{guard := GuardPid}})
  when is_pid(GuardPid) ->
    case maps:get(guard_mref, ScopedLeases, undefined) of
        undefined -> ok;
        GuardMRef -> erlang:demonitor(GuardMRef, [flush])
    end,
    %% A guard that died before cleanup has already lost its leases; the
    %% release call must not crash the coordinator's terminal transition.
    try soma_delegate_lease_guard:release_all(GuardPid) of
        ok -> ok
    catch
        exit:{noproc, _CallDetails} -> ok;
        exit:{normal, _CallDetails} -> ok;
        exit:{shutdown, _CallDetails} -> ok
    end,
    _ = supervisor:terminate_child(soma_delegate_lease_sup, GuardPid),
    ok;
release_scoped_leases(_Data) ->
    ok.

initial_checkpoint(Opts) ->
    maps:get(context_checkpoint, Opts, maps:get(checkpoint, Opts, #{})).

configured_tool_policy(RuntimeOptions) ->
    Default =
        application:get_env(
          soma_actor, service_policy, #{allowed_tools => []}),
    case maps:get(tool_policy, RuntimeOptions, Default) of
        Policy when is_map(Policy) -> Policy;
        _InvalidPolicy -> #{allowed_tools => []}
    end.

adaptive_round_sequence(RoundSequence) when is_list(RoundSequence) ->
    lists:any(fun adaptive_round_entry/1, RoundSequence);
adaptive_round_sequence(_InvalidRoundSequence) ->
    false.

adaptive_round_entry(Work) when is_map(Work) ->
    adaptive_round_work(Work);
adaptive_round_entry(_PreparedOrInvalidEntry) ->
    false.

enable_adaptive_events(Work, Data) ->
    case adaptive_round_work(Work) of
        true -> Data#{adaptive_events := true};
        false -> Data
    end.

adaptive_round_work(#{llm := #{provider := openai_compat}}) ->
    true;
adaptive_round_work(#{llm := #{directive := proposal}}) ->
    true;
adaptive_round_work(_LegacyRoundWork) ->
    false.

emit_delegate_event(
  EventType, Round, Outcome,
  #{task_id := TaskId, correlation_id := CorrelationId}) ->
    soma_delegate_event:append(
      EventType, TaskId, CorrelationId, Round, Outcome).

emit_round_completed(RoundId, Outcome, Data) ->
    emit_delegate_event(
      <<"delegate.round.completed">>, RoundId, Outcome, Data).

checkpoint_ingress(
  Data = #{ingress_pid := IngressPid,
           task_id := TaskId,
           counters := Usage,
           mutation_ledger := Mutations,
           unknown_outcome_ledger := UnknownOutcomes,
           task_artifacts := Artifacts}) ->
    ActiveRound = maps:get(active_round, Data, undefined),
    {Round, StateInvocations, UnsafeInvocations} =
        case ActiveRound of
            RoundData when is_map(RoundData) ->
                {maps:get(round_id, RoundData, 0),
                 active_state_invocations(RoundData),
                 active_unsafe_invocations(RoundData)};
            undefined ->
                {0, [], []}
        end,
    Checkpoint =
        #{adaptive_events => maps:get(adaptive_events, Data, false),
          usage => Usage,
          mutation_ledger => Mutations,
          unknown_outcome_ledger => UnknownOutcomes,
          artifacts => Artifacts,
          round => Round,
          state_invocations => StateInvocations,
          unsafe_invocations => UnsafeInvocations},
    IngressPid ! {delegate_checkpoint, TaskId, self(), Checkpoint},
    ok.

action_tool_call_ids(undefined) ->
    [];
action_tool_call_ids(RunId) when is_binary(RunId) ->
    [ToolCallId
     || #{event_type := <<"tool.started">>,
          tool_call_id := ToolCallId} <-
            soma_event_store:by_run(event_store_pid(), RunId),
        is_binary(ToolCallId)].

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

public_projection(
  #{cleanup_started := true, terminal_result := Projection})
  when is_map(Projection) ->
    Projection;
public_projection(Data) ->
    maps:with([request_id, task_id, correlation_id, status], Data).

initial_counters() ->
    #{rounds => 0,
      llm_calls => 0,
      tool_calls => 0,
      prompt_tokens => 0}.

reserve_child_counter(llm_calls, Units, Data) ->
    case reserve_counter(llm_calls, Units, Data) of
        {ok, LlmReservedData} ->
            {ok, reserve_prompt_estimate(LlmReservedData)};
        {error, Limit} ->
            {error, Limit}
    end;
reserve_child_counter(tool_calls, Units, Data) ->
    reserve_counter(tool_calls, Units, Data).

reserve_prompt_estimate(
  Data = #{active_round := ActiveRound,
           counters := Counters}) ->
    EstimatedPromptTokens =
        maps:get(prompt_tokens_estimate, ActiveRound, 0),
    CurrentPromptTokens = maps:get(prompt_tokens, Counters, 0),
    ReservedCounters =
        Counters#{prompt_tokens :=
                      CurrentPromptTokens + EstimatedPromptTokens},
    ReservedRound =
        ActiveRound#{prompt_tokens_reserved := EstimatedPromptTokens},
    Data#{active_round := ReservedRound,
          counters := ReservedCounters}.

reserve_counter(_Counter, 0, Data) ->
    {ok, Data};
reserve_counter(Counter, Units, Data) ->
    case counter_available(Counter, Units, Data) of
        true ->
            {ok, consume_counter(Counter, Units, Data)};
        false ->
            {error, counter_limit(Counter)}
    end.

counter_available(Counter, Units,
                  #{budget_limits := Budgets, counters := Counters}) ->
    Limit = counter_limit(Counter),
    Current = maps:get(Counter, Counters, 0),
    case maps:get(Limit, Budgets, undefined) of
        undefined ->
            true;
        Max when is_integer(Max), Max >= 0 ->
            Current + Units =< Max;
        _InvalidLimit ->
            false
    end.

consume_counter(Counter, Units, Data = #{counters := Counters}) ->
    Current = maps:get(Counter, Counters, 0),
    Data#{counters := maps:put(Counter, Current + Units, Counters)}.

counter_limit(rounds) -> max_rounds;
counter_limit(llm_calls) -> max_llm_calls;
counter_limit(tool_calls) -> max_tool_calls.

budget_projection(Limit) ->
    #{status => failed,
      result => {budget_exceeded, Limit}}.

context_budget_projection() ->
    #{status => failed,
      result => context_budget_exceeded}.

accounted_prompt_tokens(EstimatedPromptTokens, _Budgets) ->
    EstimatedPromptTokens.

terminal_projection(
  Projection,
  #{request_id := RequestId,
    task_id := TaskId,
    correlation_id := CorrelationId,
    task_artifacts := TaskArtifacts,
    mutation_ledger := Mutations,
    unknown_outcome_ledger := UnknownOutcomes,
    counters := Usage}) ->
    Status = honest_terminal_status(
               maps:get(status, Projection, failed),
               UnknownOutcomes),
    #{request_id => RequestId,
      task_id => TaskId,
      correlation_id => CorrelationId,
      status => Status,
      result => maps:get(result, Projection, undefined),
      artifacts => maps:get(artifacts, Projection, TaskArtifacts),
      mutations => Mutations,
      unknown_outcomes => UnknownOutcomes,
      usage => Usage,
      trace_ref => CorrelationId}.

honest_terminal_status(succeeded, [_Unknown | _]) ->
    in_doubt;
honest_terminal_status(Status, _UnknownOutcomes)
  when Status =:= succeeded; Status =:= failed;
       Status =:= rejected; Status =:= timeout;
       Status =:= cancelled; Status =:= in_doubt ->
    Status;
honest_terminal_status(_InvalidStatus, _UnknownOutcomes) ->
    failed.

terminal_event_data(#{reason := Reason}, Data) ->
    Data#{reason => soma_delegate_event:reason_class(Reason)};
terminal_event_data(_Projection, Data) ->
    maps:remove(reason, Data).
