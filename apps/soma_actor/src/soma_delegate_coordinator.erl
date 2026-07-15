%% @doc One temporary delegated-task owner. It starts inert so the ingress can
%% install its request route and monitor before allowing task work to begin.
-module(soma_delegate_coordinator).

-behaviour(gen_statem).

-define(DEFAULT_ROUND_TIMEOUT_MS, 120000).
-define(ROUND_FORCED_STOP_MS, 1000).
-define(MAX_ROUND_SNAPSHOT_BYTES, 65536).
-define(MAX_ROUND_RESULT_BYTES, 16384).

-export([start_link/1, status/1, cancel/2]).
-export([init/1, callback_mode/0, handle_event/4]).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

status(CoordinatorPid) when is_pid(CoordinatorPid) ->
    gen_statem:call(CoordinatorPid, status).

cancel(CoordinatorPid, TaskId) when is_pid(CoordinatorPid) ->
    gen_statem:cast(CoordinatorPid, {cancel, TaskId}).

init(Opts = #{request_id := RequestId,
              task_id := TaskId,
              correlation_id := CorrelationId,
              ingress_pid := IngressPid})
  when is_binary(RequestId), is_binary(TaskId), is_binary(CorrelationId),
       is_pid(IngressPid) ->
    Data = #{request_id => RequestId,
             task_id => TaskId,
             correlation_id => CorrelationId,
             ingress_pid => IngressPid,
             status => accepted,
             objective => maps:get(objective, Opts, undefined),
             output_contract => maps:get(output_contract, Opts, undefined),
             context_checkpoint => initial_checkpoint(Opts),
             budgets => maps:get(budgets, Opts, #{}),
             usage => #{},
             mutation_ledger => [],
             unknown_outcome_ledger => [],
             recent_round_data => undefined,
             scoped_leases =>
                 #{requests => maps:get(lease_requests, Opts, []),
                   handles => #{},
                   guard => undefined},
             next_round_id => 1,
             active_round => undefined,
             cleanup_started => false,
             terminal_result => undefined,
             round_sequence => maps:get(round_sequence, Opts, [])},
    {ok, awaiting_start, Data}.

callback_mode() ->
    handle_event_function.

handle_event(info, {delegate_begin, TaskId}, awaiting_start,
             Data = #{task_id := TaskId}) ->
    RunningData = Data#{status := running},
    ok = emit_delegate_event(
           <<"delegate.task.running">>, 0, RunningData, RunningData),
    begin_task(RunningData);
handle_event({call, From}, status, _StateName, Data) ->
    {keep_state, Data,
     [{reply, From, {ok, public_projection(Data)}}]};
handle_event(info,
             {delegate_status, TaskId, ReplyTo, StatusRef},
             _StateName,
             Data = #{task_id := TaskId})
  when is_pid(ReplyTo), is_reference(StatusRef) ->
    ReplyTo !
        {delegate_status_reply, TaskId, self(), StatusRef,
         {ok, public_projection(Data)}},
    {keep_state, Data};
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
             {delegate_unsafe_action_dispatched,
              TaskId, RoundId, WorkerPid, WorkerIdentity,
              ResultCapability, InvocationIdentity},
             running,
             Data = #{task_id := TaskId,
                      active_round :=
                          ActiveRound =
                              #{round_id := RoundId,
                                worker_pid := WorkerPid,
                                worker_identity := WorkerIdentity,
                                result_capability := ResultCapability,
                                unsafe_action_dispatched := false}})
  when is_map(InvocationIdentity) ->
    MarkedRound =
        ActiveRound#{unsafe_action_dispatched := true,
                     unsafe_invocation := InvocationIdentity},
    {keep_state, Data#{active_round := MarkedRound}};
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
                                cancel_status := timeout}}) ->
    exit(WorkerPid, kill),
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

start_round(Data = #{round_sequence := [RoundEntry | Remaining],
                    task_id := TaskId,
                    correlation_id := CorrelationId,
                    next_round_id := RoundId})
  ->
    case round_snapshot(Data) of
        {ok, Snapshot} ->
            prepare_and_start_round(
              RoundEntry, Remaining, Snapshot, TaskId,
              CorrelationId, RoundId, Data);
        {error, snapshot_too_large} ->
            fail_before_round(Data, snapshot_too_large)
    end.

prepare_and_start_round(
  RoundEntry, Remaining, Snapshot, TaskId, CorrelationId, RoundId, Data) ->
    case prepare_round_work(RoundEntry, Snapshot) of
        {ok, Work} ->
            start_round_worker(
              Work, Remaining, Snapshot, TaskId,
              CorrelationId, RoundId, Data);
        {error, invalid_round_sequence} ->
            fail_before_round(Data, invalid_round_sequence)
    end.

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
                            unsafe_action_dispatched => false,
                            unsafe_invocation => undefined},
            StartedData = Data#{round_sequence := Remaining,
                                next_round_id := RoundId + 1,
                                active_round := ActiveRound},
            ok = emit_delegate_event(
                   <<"delegate.round.started">>, RoundId,
                   StartedData, StartedData),
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

commit_finished_round(
  _Result, RoundId,
  #{cancel_status := timeout,
    unsafe_action_dispatched := false},
  Data) ->
    ActiveRound = maps:get(active_round, Data),
    Failure = round_timeout_failure(RoundId),
    ClearedData =
        clear_committed_round(
          Failure, RoundId, ActiveRound, Data),
    continue_after_pre_stateful_failure(
      Failure, ClearedData);
commit_finished_round(
  Result, RoundId,
  ActiveRound = #{cancel_status := cancelled}, Data) ->
    CommittedData = commit_round_deltas(Result, Data),
    Projection = #{status => cancelled, round => RoundId},
    ClearedData =
        clear_committed_round(
          Projection, RoundId, ActiveRound, CommittedData),
    start_cleanup(Projection, ClearedData);
commit_finished_round(Result, RoundId, ActiveRound, Data) ->
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
    ClearedData.

commit_round_deltas(Result, Data) ->
    CheckpointData =
        case maps:find(checkpoint, Result) of
            {ok, Checkpoint} ->
                Data#{context_checkpoint := Checkpoint};
            error ->
                Data
        end,
    UsageData =
        case maps:find(usage, Result) of
            {ok, Usage} when is_map(Usage) ->
                CheckpointData#{usage := Usage};
            _MissingOrInvalidUsage ->
                CheckpointData
        end,
    MutationData =
        case maps:find(mutation, Result) of
            {ok, Mutation} ->
                MutationLedger = maps:get(mutation_ledger, UsageData),
                UsageData#{mutation_ledger :=
                               MutationLedger ++ [Mutation]};
            error ->
                UsageData
        end,
    UnknownOutcomeData =
        case maps:find(unknown_outcome, Result) of
            {ok, UnknownOutcome} ->
                UnknownOutcomeLedger =
                    maps:get(unknown_outcome_ledger, MutationData),
                MutationData#{unknown_outcome_ledger :=
                                  UnknownOutcomeLedger ++
                                      [UnknownOutcome]};
            error ->
                MutationData
        end,
    case maps:find(terminal_result, Result) of
        {ok, TerminalResult} ->
            UnknownOutcomeData#{terminal_result := TerminalResult};
        error ->
            UnknownOutcomeData
    end.

advance_after_round(
  #{status := succeeded, decision := continue}, _RoundId,
  Data = #{round_sequence := [_NextWork | _Remaining]}) ->
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

handle_round_worker_down(ActiveRound, RoundId, Data) ->
    case {maps:get(unsafe_action_dispatched, ActiveRound, false),
          maps:get(cancel_status, ActiveRound, undefined)} of
        {true, _CancelStatus} ->
            finish_lost_unsafe_result(ActiveRound, RoundId, Data);
        {false, cancelled} ->
            Projection = worker_down_projection(ActiveRound, RoundId),
            ok = emit_round_completed(RoundId, Projection, Data),
            finish_worker_down(
              Projection, Data);
        {false, undefined} ->
            Failure = round_worker_crash_failure(RoundId),
            ok = emit_round_completed(RoundId, Failure, Data),
            continue_after_pre_stateful_failure(
              Failure,
              Data#{active_round := undefined});
        {false, timeout} ->
            Failure = round_timeout_failure(RoundId),
            ok = emit_round_completed(RoundId, Failure, Data),
            continue_after_pre_stateful_failure(
              Failure,
              Data#{active_round := undefined});
        _OtherWorkerLoss ->
            Projection = worker_down_projection(ActiveRound, RoundId),
            ok = emit_round_completed(RoundId, Projection, Data),
            finish_worker_down(
              Projection, Data)
    end.

finish_lost_unsafe_result(ActiveRound, RoundId, Data) ->
    InvocationIdentity = maps:get(unsafe_invocation, ActiveRound),
    Mutation = InvocationIdentity#{round => RoundId},
    UnknownOutcome =
        #{round => RoundId,
          invocation => InvocationIdentity,
          outcome => unknown},
    MutationLedger = maps:get(mutation_ledger, Data),
    UnknownOutcomeLedger = maps:get(unknown_outcome_ledger, Data),
    Projection = #{status => in_doubt,
                   reason => unsafe_result_lost,
                   round => RoundId},
    ok = emit_round_completed(RoundId, Projection, Data),
    finish_worker_down(
      Projection,
      Data#{mutation_ledger := MutationLedger ++ [Mutation],
            unknown_outcome_ledger :=
                UnknownOutcomeLedger ++ [UnknownOutcome],
            recent_round_data := Projection}).

finish_worker_down(Projection, Data) ->
    start_cleanup(Projection, Data#{active_round := undefined}).

continue_after_pre_stateful_failure(
  Failure, Data = #{round_sequence := [_NextRound | _Remaining]}) ->
    begin_task(
      Data#{status := running,
            recent_round_data := Failure});
continue_after_pre_stateful_failure(Failure, Data) ->
    start_cleanup(Failure, Data#{recent_round_data := Failure}).

start_cleanup(Projection, Data = #{cleanup_started := false}) ->
    Status = maps:get(status, Projection),
    CleanupData = Data#{status := Status,
                        cleanup_started := true,
                        terminal_result := Projection},
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

arm_forced_stop_timer(
  timeout, TaskId, RoundId, WorkerPid,
  WorkerIdentity, ResultCapability) ->
    erlang:start_timer(
      ?ROUND_FORCED_STOP_MS, self(),
      {delegate_round_forced_stop, TaskId, RoundId, WorkerPid,
       WorkerIdentity, ResultCapability});
arm_forced_stop_timer(
  _Status, _TaskId, _RoundId, _WorkerPid,
  _WorkerIdentity, _ResultCapability) ->
    undefined.

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
        lists:member(maps:get(status, Result, invalid),
                     [succeeded, failed, timeout, cancelled]);
valid_round_result(_Result) ->
    false.

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
    case byte_size(term_to_binary(Snapshot, [deterministic])) =<
             ?MAX_ROUND_SNAPSHOT_BYTES of
        true -> {ok, Snapshot};
        false -> {error, snapshot_too_large}
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
            Handles = soma_delegate_lease_guard:handles(GuardPid),
            UpdatedLeases = ScopedLeases#{requests := [],
                                          handles := Handles,
                                          guard := GuardPid},
            {ok, Data#{scoped_leases := UpdatedLeases}};
        {error, _Reason} ->
            {error, lease_acquisition_failed, Data}
    end.

release_scoped_leases(
  #{scoped_leases := #{guard := GuardPid}})
  when is_pid(GuardPid) ->
    ok = soma_delegate_lease_guard:release_all(GuardPid),
    _ = supervisor:terminate_child(soma_delegate_lease_sup, GuardPid),
    ok;
release_scoped_leases(_Data) ->
    ok.

initial_checkpoint(Opts) ->
    maps:get(context_checkpoint, Opts, maps:get(checkpoint, Opts, #{})).

emit_delegate_event(
  EventType, Round, Outcome,
  #{task_id := TaskId, correlation_id := CorrelationId}) ->
    soma_delegate_event:append(
      EventType, TaskId, CorrelationId, Round, Outcome).

emit_round_completed(RoundId, Outcome, Data) ->
    emit_delegate_event(
      <<"delegate.round.completed">>, RoundId, Outcome, Data).

public_projection(Data) ->
    maps:with([request_id, task_id, correlation_id, status], Data).
