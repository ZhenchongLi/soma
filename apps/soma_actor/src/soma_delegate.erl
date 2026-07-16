%% @doc Serialized production ingress for delegated tasks. One bounded request
%% identity is admitted once and routed to one temporary coordinator.
-module(soma_delegate).

-behaviour(gen_server).

-define(MAX_TERMINAL_PROJECTION_BYTES, 4096).
-define(MAX_USAGE_COUNTER, 16#ffffffffffffffff).
-define(FORWARDED_REQUEST_TIMEOUT_MS, 2500).

-export([start_link/0, submit/1, status/1, cancel/1, artifact_slice/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

submit(TaskSpec) ->
    gen_server:call(?MODULE, {submit, TaskSpec}).

status(TaskId) ->
    gen_server:call(?MODULE, {status, TaskId}).

cancel(TaskId) ->
    gen_server:call(?MODULE, {cancel, TaskId}).

artifact_slice(TaskId, Handle, Offset, RequestedBytes) ->
    gen_server:call(
      ?MODULE,
      {artifact_slice, TaskId, Handle, Offset, RequestedBytes}).

init([]) ->
    {ok, #{requests => #{},
           tasks => #{},
           monitors => #{},
           checkpoints => #{},
           status_requests => #{}}}.

handle_call({submit, Request0}, _From, State) ->
    case soma_delegate_request:normalize(Request0) of
        {ok, Request = #{request_id := RequestId}} ->
            submit_request(RequestId, Request, State);
        {error, invalid_delegate_request} = Error ->
            {reply, Error, State}
    end;
handle_call({status, TaskId}, From, State) ->
    status_task(TaskId, From, State);
handle_call({cancel, TaskId}, From, State) ->
    cancel_task(TaskId, From, State);
handle_call(
  {artifact_slice, TaskId, Handle, Offset, RequestedBytes},
  _From, State) ->
    {reply,
     soma_delegate_artifact_store:slice(
       TaskId, Handle, Offset, RequestedBytes),
     State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(
  {delegate_status_reply, TaskId, CoordinatorPid, StatusRef, Reply},
  State) ->
    {noreply,
     reply_status_request(
       TaskId, CoordinatorPid, StatusRef, Reply, State)};
handle_info(
  {timeout, TimerRef,
   {delegate_status_request_timeout, StatusRef}},
  State) ->
    {noreply,
     expire_status_request(StatusRef, TimerRef, State)};
handle_info(
  {timeout, TimerRef,
   {delegate_cancel_waiter_timeout, TaskId, WaiterRef}},
  State) ->
    {noreply,
     expire_cancel_waiter(
       TaskId, WaiterRef, TimerRef, State)};
handle_info(
  {delegate_checkpoint, TaskId, CoordinatorPid, Checkpoint}, State)
  when is_binary(TaskId), is_pid(CoordinatorPid), is_map(Checkpoint) ->
    {noreply,
     store_coordinator_checkpoint(
       TaskId, CoordinatorPid, Checkpoint, State)};
handle_info({'DOWN', MRef, process, Pid, _Reason}, State) ->
    case remove_dead_status_caller(MRef, Pid, State) of
        {removed, UpdatedState} ->
            {noreply, UpdatedState};
        not_found ->
            case remove_dead_cancel_caller(MRef, Pid, State) of
                {removed, UpdatedState} ->
                    {noreply, UpdatedState};
                not_found ->
                    {noreply,
                     remove_active_coordinator(MRef, Pid, State)}
            end
    end;
handle_info({delegate_terminal, TaskId, CoordinatorPid, Projection}, State) ->
    {noreply,
     store_terminal_projection(
       TaskId, CoordinatorPid, Projection, State)};
handle_info(_Info, State) ->
    {noreply, State}.

status_task(TaskId, From,
            State = #{tasks := Tasks,
                      status_requests := StatusRequests}) ->
    case maps:get(TaskId, Tasks, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        #{terminal_projection := Projection}
          when is_map(Projection) ->
            {reply, {ok, public_projection(Projection)}, State};
        #{coordinator_pid := CoordinatorPid} when is_pid(CoordinatorPid) ->
            StatusRef = make_ref(),
            {CallerPid, _ReplyTag} = From,
            CallerMRef = erlang:monitor(process, CallerPid),
            TimerRef =
                erlang:start_timer(
                  ?FORWARDED_REQUEST_TIMEOUT_MS, self(),
                  {delegate_status_request_timeout, StatusRef}),
            CoordinatorPid !
                {delegate_status, TaskId, self(), StatusRef},
            StatusRequest = #{task_id => TaskId,
                              coordinator_pid => CoordinatorPid,
                              caller_pid => CallerPid,
                              caller_mref => CallerMRef,
                              timer_ref => TimerRef,
                              from => From},
            {noreply,
             State#{status_requests :=
                        maps:put(
                          StatusRef, StatusRequest,
                          StatusRequests)}}
    end.

cancel_task(TaskId, From, State = #{tasks := Tasks}) ->
    case maps:get(TaskId, Tasks, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        #{terminal_projection := #{status := cancelled} = Projection} ->
            {reply, {ok, public_projection(Projection)}, State};
        #{terminal_projection := Projection} when is_map(Projection) ->
            {reply, {error, not_running}, State};
        Route = #{coordinator_pid := CoordinatorPid}
          when is_pid(CoordinatorPid) ->
            Waiters = maps:get(cancel_waiters, Route, #{}),
            WaiterRef = make_ref(),
            {CallerPid, _ReplyTag} = From,
            CallerMRef = erlang:monitor(process, CallerPid),
            TimerRef =
                erlang:start_timer(
                  ?FORWARDED_REQUEST_TIMEOUT_MS, self(),
                  {delegate_cancel_waiter_timeout,
                   TaskId, WaiterRef}),
            Waiter = #{caller_pid => CallerPid,
                       caller_mref => CallerMRef,
                       timer_ref => TimerRef,
                       from => From},
            UpdatedRoute =
                Route#{cancel_waiters =>
                           maps:put(WaiterRef, Waiter, Waiters),
                       cancel_requested => true},
            case maps:get(cancel_requested, Route, false) of
                false ->
                    soma_delegate_coordinator:cancel(
                      CoordinatorPid, TaskId);
                true ->
                    ok
            end,
            {noreply,
             State#{tasks := maps:put(TaskId, UpdatedRoute, Tasks)}}
    end.

submit_request(RequestId, Request,
               State = #{requests := Requests, tasks := Tasks}) ->
    case maps:find(RequestId, Requests) of
        {ok, TaskId} ->
            Route = maps:get(TaskId, Tasks),
            {reply, {ok, maps:get(accepted_handle, Route)}, State};
        error ->
            start_new_request(RequestId, Request, State)
    end.

start_new_request(RequestId, Request, State) ->
    TaskId = mint_task_id(),
    CorrelationId =
        resolve_correlation_id(
          maps:get(correlation_id, Request, default), TaskId),
    Handle = #{status => accepted,
               request_id => RequestId,
               task_id => TaskId,
               correlation_id => CorrelationId},
    CoordinatorRequest = Request#{correlation_id => CorrelationId},
    BudgetLimits =
        soma_delegate_request:effective_budgets(CoordinatorRequest),
    CoordinatorOpts =
        #{request => CoordinatorRequest,
          task_id => TaskId,
          ingress_pid => self(),
          budget_limits => BudgetLimits,
          runtime_options => trusted_runtime_options()},
    start_coordinator(CoordinatorOpts, Handle, State).

start_coordinator(CoordinatorOpts,
                  Handle = #{request_id := RequestId, task_id := TaskId},
                  State = #{requests := Requests,
                            tasks := Tasks,
                            monitors := Monitors}) ->
    case soma_delegate_coordinator_sup:start_coordinator(CoordinatorOpts) of
        {ok, CoordinatorPid} ->
            MRef = erlang:monitor(process, CoordinatorPid),
            Route = #{request_id => RequestId,
                      task_id => TaskId,
                      accepted_handle => Handle,
                      coordinator_pid => CoordinatorPid,
                      coordinator_mref => MRef,
                      terminal_projection => undefined},
            AdmittedState = State#{
                requests := maps:put(RequestId, TaskId, Requests),
                tasks := maps:put(TaskId, Route, Tasks),
                monitors := maps:put(MRef, TaskId, Monitors)},
            ok = soma_delegate_event:append(
                   <<"delegate.task.accepted">>, TaskId,
                   maps:get(correlation_id, Handle), 0,
                   #{status => accepted}),
            CoordinatorPid ! {delegate_begin, TaskId},
            {reply, {ok, Handle}, AdmittedState};
        {error, _Reason} ->
            {reply, {error, coordinator_start_failed}, State}
    end.

remove_active_coordinator(MRef, CoordinatorPid,
                          State = #{tasks := Tasks,
                                    monitors := Monitors,
                                    checkpoints := Checkpoints,
                                    status_requests := StatusRequests}) ->
    case maps:take(MRef, Monitors) of
        {TaskId, RemainingMonitors} ->
            Route = maps:get(TaskId, Tasks),
            {UpdatedRoute, RemainingStatusRequests} =
                case maps:get(coordinator_pid, Route, undefined) of
                    CoordinatorPid ->
                        Checkpoint =
                            maps:get(
                              TaskId, Checkpoints,
                              empty_coordinator_checkpoint()),
                        Projection =
                            bounded_terminal_projection(
                              coordinator_crashed_projection(Checkpoint),
                              Route),
                        PublicProjection =
                            public_projection(Projection),
                        ok = soma_delegate_event:append(
                               <<"delegate.task.terminal">>, TaskId,
                               route_correlation_id(Route), 0,
                               coordinator_crashed_event_outcome(
                                 Projection, Checkpoint)),
                        reply_cancel_waiters(Route,
                                             PublicProjection),
                        {terminal_route(Route, Projection),
                         reply_status_requests(
                           TaskId, CoordinatorPid,
                           {ok, PublicProjection},
                           StatusRequests)};
                    _OtherPid ->
                        {Route, StatusRequests}
                end,
            State#{tasks := maps:put(TaskId, UpdatedRoute, Tasks),
                   monitors := RemainingMonitors,
                   checkpoints := maps:remove(TaskId, Checkpoints),
                   status_requests := RemainingStatusRequests};
        error ->
            State
    end.

store_terminal_projection(
  TaskId, CoordinatorPid, Projection,
  State = #{tasks := Tasks,
            monitors := Monitors,
            checkpoints := Checkpoints})
  when is_map(Projection) ->
    case maps:get(TaskId, Tasks, undefined) of
        Route = #{coordinator_pid := CoordinatorPid,
                  coordinator_mref := MRef,
                  terminal_projection := undefined} ->
            _ = erlang:demonitor(MRef, [flush]),
            BoundedProjection =
                bounded_terminal_projection(Projection, Route),
            PublicProjection =
                public_projection(BoundedProjection),
            reply_cancel_waiters(Route, PublicProjection),
            TerminalRoute =
                terminal_route(Route, BoundedProjection),
            CoordinatorPid ! {delegate_terminal_stored, TaskId},
            State#{tasks := maps:put(TaskId, TerminalRoute, Tasks),
                   monitors := maps:remove(MRef, Monitors),
                   checkpoints := maps:remove(TaskId, Checkpoints),
                   status_requests :=
                       reply_status_requests(
                         TaskId, CoordinatorPid,
                         {ok, PublicProjection},
                         maps:get(status_requests, State))};
        _StaleOrMismatchedCoordinator ->
            State
    end;
store_terminal_projection(_TaskId, _CoordinatorPid, _Projection, State) ->
    State.

store_coordinator_checkpoint(
  TaskId, CoordinatorPid, Checkpoint,
  State = #{tasks := Tasks, checkpoints := Checkpoints}) ->
    case maps:get(TaskId, Tasks, undefined) of
        #{coordinator_pid := CoordinatorPid,
          terminal_projection := undefined} ->
            State#{checkpoints :=
                       maps:put(TaskId, Checkpoint, Checkpoints)};
        _StaleOrTerminalTask ->
            State
    end.

reply_cancel_waiters(Route, Projection) ->
    maps:foreach(
      fun(_WaiterRef,
          #{caller_mref := CallerMRef,
            timer_ref := TimerRef,
            from := From}) ->
              cancel_timer(TimerRef),
              _ = erlang:demonitor(CallerMRef, [flush]),
              gen_server:reply(From, {ok, Projection})
      end,
      maps:get(cancel_waiters, Route, #{})).

reply_status_request(
  TaskId, CoordinatorPid, StatusRef, Reply,
  State = #{status_requests := StatusRequests}) ->
    case maps:get(StatusRef, StatusRequests, undefined) of
        #{task_id := TaskId,
          coordinator_pid := CoordinatorPid,
          caller_mref := CallerMRef,
          timer_ref := TimerRef,
          from := From} ->
            cancel_timer(TimerRef),
            _ = erlang:demonitor(CallerMRef, [flush]),
            gen_server:reply(From, Reply),
            State#{status_requests :=
                       maps:remove(StatusRef, StatusRequests)};
        _StaleOrMismatchedReply ->
            State
    end.

reply_status_requests(
  TaskId, CoordinatorPid, Reply, StatusRequests) ->
    maps:fold(
      fun(StatusRef,
          #{task_id := PendingTaskId,
            coordinator_pid := PendingCoordinatorPid,
            caller_mref := CallerMRef,
            timer_ref := TimerRef,
            from := From} = StatusRequest,
          Remaining) ->
              case {PendingTaskId, PendingCoordinatorPid} of
                  {TaskId, CoordinatorPid} ->
                      cancel_timer(TimerRef),
                      _ = erlang:demonitor(CallerMRef, [flush]),
                      gen_server:reply(From, Reply),
                      Remaining;
                  _OtherRequest ->
                      maps:put(StatusRef, StatusRequest, Remaining)
              end
      end,
      #{}, StatusRequests).

remove_dead_status_caller(
  CallerMRef, CallerPid,
  State = #{status_requests := StatusRequests}) ->
    {Removed, Remaining} =
        maps:fold(
          fun(StatusRef,
              StatusRequest =
                  #{caller_pid := PendingCallerPid,
                    caller_mref := PendingCallerMRef,
                    timer_ref := TimerRef},
              {Found, Acc}) ->
                  case {PendingCallerPid, PendingCallerMRef} of
                      {CallerPid, CallerMRef} ->
                          cancel_timer(TimerRef),
                          {true, Acc};
                      _OtherCaller ->
                          {Found,
                           maps:put(
                             StatusRef, StatusRequest, Acc)}
                  end
          end,
          {false, #{}}, StatusRequests),
    case Removed of
        true ->
            {removed, State#{status_requests := Remaining}};
        false ->
            not_found
    end.

expire_status_request(
  StatusRef, TimerRef,
  State = #{status_requests := StatusRequests}) ->
    case maps:get(StatusRef, StatusRequests, undefined) of
        #{timer_ref := TimerRef,
          caller_mref := CallerMRef,
          from := From} ->
            _ = erlang:demonitor(CallerMRef, [flush]),
            gen_server:reply(From, {error, timeout}),
            State#{status_requests :=
                       maps:remove(StatusRef, StatusRequests)};
        _StaleOrReplacedRequest ->
            State
    end.

expire_cancel_waiter(
  TaskId, WaiterRef, TimerRef,
  State = #{tasks := Tasks}) ->
    case maps:get(TaskId, Tasks, undefined) of
        Route when is_map(Route) ->
            Waiters = maps:get(cancel_waiters, Route, #{}),
            case maps:get(WaiterRef, Waiters, undefined) of
                #{timer_ref := TimerRef,
                  caller_mref := CallerMRef,
                  from := From} ->
                    _ = erlang:demonitor(CallerMRef, [flush]),
                    gen_server:reply(From, {error, timeout}),
                    Remaining = maps:remove(WaiterRef, Waiters),
                    UpdatedRoute =
                        route_with_cancel_waiters(
                          Route, Remaining),
                    State#{tasks :=
                               maps:put(
                                 TaskId, UpdatedRoute, Tasks)};
                _StaleOrReplacedWaiter ->
                    State
            end;
        _MissingTask ->
            State
    end.

remove_dead_cancel_caller(
  CallerMRef, CallerPid,
  State = #{tasks := Tasks}) ->
    {Removed, UpdatedTasks} =
        maps:fold(
          fun(TaskId, Route, {Found, Acc}) ->
                  case remove_cancel_waiter_by_monitor(
                         CallerMRef, CallerPid, Route) of
                      {removed, UpdatedRoute} ->
                          {true,
                           maps:put(TaskId, UpdatedRoute, Acc)};
                      not_found ->
                          {Found, maps:put(TaskId, Route, Acc)}
                  end
          end,
          {false, #{}}, Tasks),
    case Removed of
        true -> {removed, State#{tasks := UpdatedTasks}};
        false -> not_found
    end.

remove_cancel_waiter_by_monitor(CallerMRef, CallerPid, Route) ->
    Waiters = maps:get(cancel_waiters, Route, #{}),
    {Removed, Remaining} =
        maps:fold(
          fun(WaiterRef,
              Waiter = #{caller_pid := PendingCallerPid,
                         caller_mref := PendingCallerMRef,
                         timer_ref := TimerRef},
              {Found, Acc}) ->
                  case {PendingCallerPid, PendingCallerMRef} of
                      {CallerPid, CallerMRef} ->
                          cancel_timer(TimerRef),
                          {true, Acc};
                      _OtherCaller ->
                          {Found, maps:put(WaiterRef, Waiter, Acc)}
                  end
          end,
          {false, #{}}, Waiters),
    case Removed of
        true ->
            {removed,
             route_with_cancel_waiters(Route, Remaining)};
        false ->
            not_found
    end.

route_with_cancel_waiters(Route, Waiters) when map_size(Waiters) =:= 0 ->
    maps:remove(cancel_waiters, Route);
route_with_cancel_waiters(Route, Waiters) ->
    Route#{cancel_waiters => Waiters}.

cancel_timer(TimerRef) when is_reference(TimerRef) ->
    _ = erlang:cancel_timer(
          TimerRef, [{async, false}, {info, false}]),
    ok.

public_projection(Projection) ->
    Projection.

terminal_route(Route, Projection) ->
    #{request_id => maps:get(request_id, Route),
      task_id => maps:get(task_id, Route),
      accepted_handle => maps:get(accepted_handle, Route),
      terminal_projection => Projection}.

route_correlation_id(Route) ->
    maps:get(
      correlation_id, maps:get(accepted_handle, Route)).

resolve_correlation_id(default, TaskId) ->
    TaskId;
resolve_correlation_id(CorrelationId, _TaskId) ->
    CorrelationId.

trusted_runtime_options() ->
    case application:get_env(soma_actor, delegate_runtime_options, #{}) of
        RuntimeOptions when is_map(RuntimeOptions) -> RuntimeOptions;
        _InvalidRuntimeOptions -> #{}
    end.

mint_task_id() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<"delegate-task-", Suffix/binary>>.

empty_coordinator_checkpoint() ->
    #{adaptive_events => false,
      usage => #{rounds => 0,
                 llm_calls => 0,
                 tool_calls => 0,
                 prompt_tokens => 0},
      mutation_ledger => [],
      unknown_outcome_ledger => [],
      artifacts => [],
      round => 0,
      state_invocations => [],
      unsafe_invocations => []}.

coordinator_crashed_projection(Checkpoint) ->
    Mutations0 = checkpoint_list(mutation_ledger, Checkpoint),
    UnknownOutcomes0 =
        checkpoint_list(unknown_outcome_ledger, Checkpoint),
    UnsafeInvocations =
        checkpoint_list(unsafe_invocations, Checkpoint),
    StateInvocations =
        case checkpoint_list(state_invocations, Checkpoint) of
            [] -> UnsafeInvocations;
            Invocations -> Invocations
        end,
    Round = checkpoint_round(Checkpoint),
    SafetyFacts =
        case maps:get(adaptive_events, Checkpoint, false) of
            true ->
                soma_delegate_safety:facts(
                  StateInvocations, UnsafeInvocations,
                  Round, event_store_pid());
            false ->
                soma_delegate_safety:unknown_facts(
                  StateInvocations, UnsafeInvocations, Round)
        end,
    Mutations =
        Mutations0 ++ maps:get(mutations, SafetyFacts, []),
    UnknownOutcomes =
        UnknownOutcomes0 ++
            maps:get(unknown_outcomes, SafetyFacts, []),
    Status =
        case UnknownOutcomes of
            [] -> failed;
            [_Unknown | _] -> in_doubt
        end,
    #{status => Status,
      result => coordinator_crashed,
      artifacts => checkpoint_list(artifacts, Checkpoint),
      mutations => Mutations,
      unknown_outcomes => UnknownOutcomes,
      usage => maps:get(
                 usage, Checkpoint,
                 maps:get(usage, empty_coordinator_checkpoint()))}.

coordinator_crashed_event_outcome(Projection, Checkpoint) ->
    #{adaptive_events => maps:get(adaptive_events, Checkpoint, false),
      status => maps:get(status, Projection),
      mutation_ledger => maps:get(mutations, Projection, []),
      unknown_outcome_ledger =>
          maps:get(unknown_outcomes, Projection, []),
      usage => maps:get(usage, Projection, #{})}.

checkpoint_list(Key, Checkpoint) ->
    case maps:get(Key, Checkpoint, []) of
        List when is_list(List) -> List;
        _InvalidList -> []
    end.

checkpoint_round(Checkpoint) ->
    case maps:get(round, Checkpoint, 0) of
        Round when is_integer(Round), Round >= 0 -> Round;
        _InvalidRound -> 0
    end.

bounded_terminal_projection(Projection, Route) ->
    AcceptedHandle = maps:get(accepted_handle, Route),
    RequestId = maps:get(request_id, AcceptedHandle),
    TaskId = maps:get(task_id, AcceptedHandle),
    CorrelationId = maps:get(correlation_id, AcceptedHandle),
    Status = terminal_status(maps:get(status, Projection, failed)),
    Result = valid_terminal_result(
               maps:get(result, Projection, undefined)),
    Usage = valid_terminal_usage_or_default(
              maps:get(usage, Projection, #{})),
    Artifacts = valid_terminal_artifacts_or_default(
                  maps:get(artifacts, Projection, [])),
    Mutations = valid_terminal_ledger_or_default(
                  maps:get(mutations, Projection, [])),
    UnknownOutcomes = valid_terminal_ledger_or_default(
                        maps:get(unknown_outcomes, Projection, [])),
    Candidate =
        #{request_id => RequestId,
          task_id => TaskId,
          correlation_id => CorrelationId,
          status => Status,
          result => Result,
          artifacts => Artifacts,
          mutations => Mutations,
          unknown_outcomes => UnknownOutcomes,
          usage => Usage,
          trace_ref => CorrelationId},
    case encoded_bytes(Candidate) =<
             ?MAX_TERMINAL_PROJECTION_BYTES of
        true ->
            Candidate;
        false ->
            overflow_terminal_projection(Candidate)
    end.

valid_terminal_result(Result) ->
    case soma_delegate_task_data:safe_term(Result) of
        true -> Result;
        false -> undefined
    end.

valid_terminal_usage_or_default(Usage) ->
    case valid_terminal_usage(Usage) of
        true -> Usage;
        false -> #{rounds => 0,
                   llm_calls => 0,
                   tool_calls => 0,
                   prompt_tokens => 0}
    end.

valid_terminal_artifacts_or_default(Artifacts) ->
    case valid_terminal_artifacts(Artifacts) of
        true -> Artifacts;
        false -> []
    end.

valid_terminal_ledger_or_default(Ledger) when is_list(Ledger) ->
    case soma_delegate_task_data:safe_term(Ledger) of
        true -> Ledger;
        false -> []
    end;
valid_terminal_ledger_or_default(_InvalidLedger) ->
    [].

overflow_terminal_projection(
  Candidate = #{mutations := Mutations,
                unknown_outcomes := UnknownOutcomes}) ->
    Compact =
        Candidate#{artifacts := [],
                   mutations := overflow_ledger(Mutations),
                   unknown_outcomes := overflow_ledger(UnknownOutcomes)},
    case encoded_bytes(Compact) =< ?MAX_TERMINAL_PROJECTION_BYTES of
        true ->
            Compact;
        false ->
            ResultBounded =
                Compact#{result := terminal_projection_too_large},
            case encoded_bytes(ResultBounded) =<
                     ?MAX_TERMINAL_PROJECTION_BYTES of
                true ->
                    ResultBounded;
                false ->
                    Minimal =
                        ResultBounded#{artifacts := [],
                                       mutations := [],
                                       unknown_outcomes := [],
                                       usage :=
                                           #{rounds => 0,
                                             llm_calls => 0,
                                             tool_calls => 0,
                                             prompt_tokens => 0}},
                    true = encoded_bytes(Minimal) =<
                               ?MAX_TERMINAL_PROJECTION_BYTES,
                    Minimal
            end
    end.

overflow_ledger([]) ->
    [];
overflow_ledger(Ledger) ->
    [#{count => length(Ledger), truncated => true}].

terminal_status(Status)
  when Status =:= succeeded; Status =:= failed;
       Status =:= rejected;
       Status =:= timeout; Status =:= cancelled;
       Status =:= in_doubt ->
    Status;
terminal_status(_InvalidStatus) ->
    failed.

encoded_bytes(Term) ->
    byte_size(term_to_binary(Term, [deterministic])).

valid_terminal_usage(Usage) when is_map(Usage) ->
    lists:sort(maps:keys(Usage)) =:=
        [llm_calls, prompt_tokens, rounds, tool_calls] andalso
        lists:all(
          fun(Value) ->
                  is_integer(Value) andalso Value >= 0 andalso
                      Value =< ?MAX_USAGE_COUNTER
          end,
          maps:values(Usage));
valid_terminal_usage(_Usage) ->
    false.

valid_terminal_artifacts(Artifacts) when is_list(Artifacts) ->
    lists:all(fun valid_terminal_artifact/1, Artifacts);
valid_terminal_artifacts(_Artifacts) ->
    false.

valid_terminal_artifact(
  #{handle := Handle, bytes := Bytes} = Artifact) ->
    lists:sort(maps:keys(Artifact)) =:= [bytes, handle] andalso
        is_binary(Handle) andalso byte_size(Handle) > 0 andalso
        is_integer(Bytes) andalso Bytes >= 0;
valid_terminal_artifact(_Artifact) ->
    false.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
