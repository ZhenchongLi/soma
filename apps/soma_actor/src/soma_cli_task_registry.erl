%% @doc Durably rebuildable CLI daemon task owner and live projection cache.
-module(soma_cli_task_registry).

-behaviour(gen_server).
-compile({no_auto_import, [register/2]}).

-export([start_link/0, start_link/1, open_admission/1, open_admission/2,
         register/2, lookup/1, start_detached_run/5, start_detached_run/6,
         cancel/1, cancel_all/0, cancel_all/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(RECOVERY_RETRY_MS, 100).
-define(OWNER_CALL_TIMEOUT_MS, 500).
-define(EVENT_STORE_CALL_TIMEOUT_MS, 1000).
-define(REGISTRY_CALL_TIMEOUT_MS, 4000).
-define(REQUEST_BUDGET_MS, 3000).

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

register(TaskId, Task) when is_map(Task) ->
    gen_server:call(?MODULE, {register, TaskId, Task}).

open_admission(Owner) when is_pid(Owner) ->
    open_admission_request(Owner, keep_tools_dir).

open_admission(Owner, ToolsDir) when is_pid(Owner) ->
    open_admission_request(Owner, {replace_tools_dir, ToolsDir}).

open_admission_request(Owner, ToolsDirUpdate) ->
    Deadline = request_deadline(),
    gen_server:call(
      ?MODULE,
      {open_admission, make_ref(), Deadline, Owner, ToolsDirUpdate},
      ?REGISTRY_CALL_TIMEOUT_MS).

lookup(TaskId) ->
    gen_server:call(?MODULE, {lookup, TaskId}).

start_detached_run(TaskId, CorrId, RunId, Steps, Store) ->
    start_detached_run(TaskId, CorrId, RunId, Steps, Store, any).

start_detached_run(TaskId, CorrId, RunId, Steps, Store, Owner) ->
    Deadline = request_deadline(),
    gen_server:call(
      ?MODULE,
      {start_detached_run, make_ref(), Deadline,
       TaskId, CorrId, RunId, Steps, Store, Owner},
      ?REGISTRY_CALL_TIMEOUT_MS).

cancel(TaskId) ->
    gen_server:call(?MODULE, {cancel, TaskId}).

cancel_all() ->
    cancel_all_request(any).

cancel_all(Owner) when is_pid(Owner) ->
    cancel_all_request(Owner).

cancel_all_request(Owner) ->
    Deadline = request_deadline(),
    gen_server:call(?MODULE,
                    {cancel_all, make_ref(), Deadline, Owner},
                    ?REGISTRY_CALL_TIMEOUT_MS).

init(Opts) ->
    %% Detached CLI runs opt out of the runtime's ownerless boot auto-resume.
    %% Recovery starts asynchronously. A full disk trail can be large or the
    %% store may be temporarily suspended; the listener may still answer read
    %% requests, but cancel/stop fail closed until the authoritative scan lands.
    %% `tool_registry' intentionally starts undefined so this owner performs and
    %% generation-checks its own config reload instead of trusting a loader call
    %% that may have raced immediately before registry startup.
    Store = runtime_event_store(),
    RecoveryRequired = Store =/= undefined orelse runtime_running(),
    Empty0 = #{tasks => #{}, runs => #{}, monitors => #{},
               tools_dir => maps:get(tools_dir, Opts, undefined),
               event_store => Store,
               tool_registry => undefined,
               admission_owner => undefined,
               admission_owner_mref => undefined},
    Empty = case RecoveryRequired of
                true -> Empty0#{recovery_scan_pending => true};
                false -> Empty0
            end,
    case RecoveryRequired of
        true -> _ = erlang:send_after(0, self(), recover_detached_tasks);
        false -> ok
    end,
    {ok, Empty}.

%% Pre-deadline mailbox forms are writes with no remaining authority after a
%% hot upgrade. Fail closed instead of assigning them an infinite lease.
handle_call({open_admission, _Owner}, _From, State) ->
    {reply, {error, request_expired}, State};
handle_call({open_admission, _Owner, _ToolsDir}, _From, State) ->
    {reply, {error, request_expired}, State};
handle_call({open_admission, _ReqId, Deadline, Owner, ToolsDirUpdate},
            _From, State) ->
    %% A listener pid is the admission generation. Rebinding in the same VM
    %% opens a fresh generation, while handlers accepted by the stopped listener
    %% retain its old pid and cannot cross this boundary later.
    case request_expired(Deadline) orelse not is_process_alive(Owner) of
        true ->
            {reply, {error, request_expired}, State};
        false ->
            Rebound0 = replace_admission_owner(State, Owner),
            Rebound = update_admission_tools_dir(
                        ToolsDirUpdate, Rebound0),
            {reply, ok, maps:remove(admission_closed, Rebound)}
    end;
handle_call({register, _TaskId, _Task}, _From,
            #{admission_closed := true} = State) ->
    {reply, {error, daemon_stopping}, State};
handle_call({register, TaskId, Task}, _From,
            #{tasks := Tasks, runs := Runs} = State) ->
    Runs1 = case maps:find(run_id, Task) of
                {ok, RunId} -> Runs#{RunId => TaskId};
                error -> Runs
            end,
    {reply, ok, State#{tasks := Tasks#{TaskId => Task}, runs := Runs1}};
handle_call({lookup, TaskId}, _From, #{tasks := Tasks} = State) ->
    Reply = case maps:find(TaskId, Tasks) of
                {ok, Task} -> {ok, Task};
                error ->
                    case maps:get(recovery_scan_pending, State, false) of
                        true -> {error, recovery_incomplete};
                        false -> {error, not_found}
                    end
            end,
    {reply, Reply, State};
handle_call({cancel, TaskId}, _From, #{tasks := Tasks} = State) ->
    case maps:find(TaskId, Tasks) of
        {ok, #{status := running} = Task} ->
            %% Persist the owner decision before touching the live process. If
            %% this VM exits after acknowledging cancel, recovery will finalize
            %% the abandoned run as cancelled without starting a fresh attempt.
            case persist_cancel_intent(Task#{task_id => TaskId}, State) of
                {ok, State1} ->
                    signal_cancel(TaskId, State1),
                    {reply, ok, State1};
                {error, Reason, State1} ->
                    %% The append outcome may be unknown. Keep the in-memory
                    %% decision sticky and never resume this task in this VM;
                    %% the error only means shutdown cannot be acknowledged as
                    %% durable yet.
                    signal_cancel(TaskId, State1),
                    schedule_cancel_intent_retry(TaskId),
                    {reply, {error, Reason}, State1}
            end;
        {ok, #{status := Status}} ->
            {reply, {error, {not_running, Status}}, State};
        error ->
            case maps:get(recovery_scan_pending, State, false) of
                true -> {reply, {error, recovery_incomplete}, State};
                false -> {reply, {error, not_found}, State}
            end
    end;
%% Mailbox compatibility across a hot code change from the pre-generation API.
handle_call(cancel_all, From, State) ->
    _ = From,
    {reply, {error, request_expired}, State};
handle_call({cancel_all, _Owner}, _From, State) ->
    {reply, {error, request_expired}, State};
handle_call({cancel_all, _ReqId, _Deadline, Owner}, _From,
            #{admission_owner := Current} = State)
  when Owner =/= any, Owner =/= Current ->
    {reply, {error, stale_daemon_generation}, State};
handle_call({cancel_all, _ReqId, Deadline, _Owner}, _From, State)
  when is_integer(Deadline) ->
    case request_expired(Deadline) of
        true ->
            %% gen_server caller timeouts do not retract mailbox messages.
            %% An expired stop request is therefore a strict no-op: it cannot
            %% close admission after the listener already reported failure.
            {reply, {error, request_expired}, State};
        false ->
            handle_cancel_all(Deadline, State)
    end;
handle_call({cancel_all, _ReqId, infinity, _Owner}, _From, State) ->
    handle_cancel_all(infinity, State);
handle_call({cancel_all_pending, _Deadline}, _From,
            #{recovery_scan_pending := true} = State) ->
    {reply, {error, cancel_intent_not_persisted}, State};
handle_call({cancel_all_pending, Deadline}, _From,
            #{tasks := Tasks} = State) ->
    %% This gen_server transition is the atomic stop/admission boundary. Any
    %% start already serialized before it is included below; every start after
    %% it observes `admission_closed'. If persistence fails, roll the gate back
    %% before replying so the still-running daemon remains usable.
    QuiescingState = State#{admission_closed => true},
    Running = [Task#{task_id => TaskId}
               || {TaskId, #{status := running} = Task} <- maps:to_list(Tasks)],
    %% `(stop)' may be followed immediately by VM halt. Synchronously journal
    %% every cancellation intent before replying; only then signal live runs.
    %% A recovery-pending task has no pid to signal, but its durable intent is
    %% enough for the next owner to terminate it without replaying a tool.
    case persist_cancel_intents(Running, QuiescingState, Deadline) of
        {ok, State1} ->
            lists:foreach(
              fun(#{task_id := TaskId}) -> signal_cancel(TaskId, State1) end,
              Running),
            case request_expired(Deadline) of
                true ->
                    %% Cancellation decisions may already be durable, so keep
                    %% them sticky and signal the old runs, but do not leave a
                    %% live listener behind a late admission-closed gate.
                    {reply, {error, request_expired},
                     maps:remove(admission_closed, State1)};
                false ->
                    {reply, ok, State1}
            end;
        {error, Reason, State1} ->
            signal_requested_cancels(State1),
            schedule_pending_cancel_intents(State1),
            {reply, {error, Reason}, maps:remove(admission_closed, State1)}
    end;
handle_call({start_detached_run, TaskId, CorrId, RunId, Steps, Store},
            _From, State) ->
    _ = {TaskId, CorrId, RunId, Steps, Store},
    {reply, {error, request_expired}, State};
handle_call(
  {start_detached_run, TaskId, CorrId, RunId, Steps, Store, Owner},
  _From, State) ->
    _ = {TaskId, CorrId, RunId, Steps, Store, Owner},
    {reply, {error, request_expired}, State};
handle_call(
  {start_detached_run, _ReqId, _Deadline,
   _TaskId, _CorrId, _RunId, _Steps, _Store, Owner},
  _From, #{admission_owner := Current} = State)
  when Owner =/= any, Owner =/= Current ->
    {reply, {error, stale_daemon_generation}, State};
handle_call(
  {start_detached_run, _ReqId, _Deadline,
   _TaskId, _CorrId, _RunId, _Steps, _Store, _Owner},
            _From, #{admission_closed := true} = State) ->
    {reply, {error, daemon_stopping}, State};
handle_call(
  {start_detached_run, _ReqId, Deadline,
   TaskId, CorrId, RunId, Steps, _Store, _Owner}, _From, State) ->
    case request_expired(Deadline) of
        true ->
            {reply, {error, request_expired}, State};
        false ->
            start_detached_before_deadline(
              TaskId, CorrId, RunId, Steps, Deadline, State)
    end.

start_detached_before_deadline(TaskId, CorrId, RunId, Steps, Deadline,
                               State) ->
    case recovery_runtime(State) of
        {ok, RuntimeStore, ReadyState} ->
            AdmissionId = new_admission_id(),
            Opts = #{run_id => RunId,
                     task_id => TaskId,
                     session_id => TaskId,
                     session_pid => self(),
                     event_store => RuntimeStore,
                     steps => Steps,
                     correlation_id => CorrId,
                     %% The runtime journals this fixed internal origin but
                     %% never interprets it. It is the durable distinction
                     %% between foreground and detached CLI runs.
                     run_origin => cli_detached,
                     %% CLI recovery must run after config tools load and have
                     %% this registry as owner, so generic auto-resume skips it.
                     auto_resume => false,
                     %% Fresh CLI admission is a durable edge/run handshake.
                     %% run.started alone is pending; recovery may execute only
                     %% after exact accepted and run-owned committed proofs.
                     admission_required => true,
                     admission_id => AdmissionId,
                     %% No effect is released until this callback observes the
                     %% paused child and completes both durable proof stages.
                     start_paused => true},
            StartResult = try start_detached_child(Opts, Deadline) of
                              Result -> Result
                          catch
                              Class:StartError ->
                                  {error, {runtime_transition,
                                           {Class, StartError}}}
                          end,
            case StartResult of
                {ok, RunPid} ->
                    case prepare_detached_child(RunPid, Deadline) of
                        ok ->
                            finish_detached_admission(
                              TaskId, CorrId, RunId, AdmissionId, RunPid,
                              RuntimeStore, Deadline, ReadyState);
                        {error, PrepareReason} ->
                            %% The paused run owns its absolute lease. If the
                            %% prepare call became commit-unknown, any durable
                            %% run.started still lacks cli.task.accepted and is
                            %% therefore non-executable during later recovery.
                            %% Kill the child explicitly: while its store append
                            %% is blocked it cannot process the lease timeout,
                            %% and repeated failed requests must not accumulate
                            %% live RunId claims behind a stalled store.
                            retire_unadmitted_child(RunPid),
                            _ = erlang:send_after(
                                  0, self(), recover_detached_tasks),
                            {reply,
                             {error, {run_start_failed, PrepareReason}},
                             ReadyState}
                    end;
                {error, Reason} ->
                    {reply, {error, {run_start_failed, Reason}}, ReadyState}
            end;
        retry ->
            {reply, {error, runtime_transition}, State}
    end.

finish_detached_admission(TaskId, CorrId, RunId, AdmissionId, RunPid, Store,
                          Deadline, State) ->
    Task = #{task_id => TaskId, run_id => RunId,
             correlation_id => CorrId,
             admission_id => AdmissionId,
             admission_required => true},
    case persist_admission_accepted(Task, Store, Deadline) of
        ok ->
            finish_detached_activation(Task, RunPid, Deadline, State);
        {error, admission_rejected} ->
            RunPid ! cancel,
            {reply, {error, admission_rejected}, State};
        {error, _CommitUnknown} ->
            %% A timed-out append is genuinely in doubt: the caller receives
            %% stable ids but never a false `(accepted ...)'. Keep the paused
            %% child visible and retry. If this registry dies first, a
            %% replacement requires the separate run-owned commit proof and
            %% therefore rejects a late accepted marker instead of executing.
            State1 = mark_admission_accept_pending(
                       TaskId, AdmissionId,
                       put_running_task(
                         TaskId, CorrId, RunId, RunPid, State)),
            schedule_admission_accept_retry(TaskId),
            {reply, admission_in_doubt_reply(Task), State1}
    end.

finish_detached_activation(
  #{task_id := TaskId, correlation_id := CorrId, run_id := RunId,
    admission_id := AdmissionId} = Task,
  RunPid, Deadline, State) ->
    State0 = mark_admission_accepted(
               TaskId, AdmissionId,
               put_running_task(TaskId, CorrId, RunId, RunPid, State)),
    case activate_detached_child(RunPid, Deadline) of
        ok ->
            State1 = mark_admission_committed(TaskId, State0),
            {reply, accepted_reply(TaskId, CorrId, RunId, RunPid), State1};
        {error, _ActivationUnknown} ->
            %% The run may have committed activation while its acknowledgement
            %% was lost. Reconcile the exact durable decision before retrying;
            %% the response remains explicitly in-doubt meanwhile.
            State1 = mark_admission_activation_pending(TaskId, State0),
            schedule_admission_accept_retry(TaskId),
            {reply, admission_in_doubt_reply(Task), State1}
    end.

accepted_reply(TaskId, CorrId, RunId, RunPid) ->
    {ok, #{task_id => TaskId,
           correlation_id => CorrId,
           run_id => RunId,
           pid => RunPid}}.

admission_in_doubt_reply(Task) ->
    {error, {admission_in_doubt,
             maps:with([task_id, correlation_id, run_id], Task)}}.

handle_cancel_all(Deadline, State) ->
    handle_call({cancel_all_pending, Deadline}, undefined, State).

start_detached_child(Opts, infinity) ->
    soma_run_sup:start_run(Opts);
start_detached_child(Opts, Deadline) ->
    case remaining_request_ms(Deadline) of
        0 -> {error, request_expired};
        Remaining -> soma_run_sup:start_run(Opts, Remaining)
    end.

activate_detached_child(RunPid, infinity) ->
    soma_run:activate_sync(RunPid, infinity, infinity);
activate_detached_child(RunPid, Deadline) ->
    case remaining_request_ms(Deadline) of
        0 -> {error, request_expired};
        Remaining ->
            try soma_run:activate_sync(RunPid, Deadline, Remaining) of
                Result -> Result
            catch
                exit:_Reason -> {error, activation_unresponsive}
            end
    end.

prepare_detached_child(RunPid, infinity) ->
    soma_run:prepare_start_sync(RunPid, infinity, infinity);
prepare_detached_child(RunPid, Deadline) ->
    case remaining_request_ms(Deadline) of
        0 -> {error, request_expired};
        Remaining ->
            try soma_run:prepare_start_sync(RunPid, Deadline, Remaining) of
                Result -> Result
            catch
                exit:_Reason -> {error, preparation_unresponsive}
            end
    end.

retire_unadmitted_child(RunPid) when is_pid(RunPid) ->
    MRef = erlang:monitor(process, RunPid),
    exit(RunPid, kill),
    receive
        {'DOWN', MRef, process, RunPid, _Reason} -> ok
    after ?OWNER_CALL_TIMEOUT_MS ->
            erlang:demonitor(MRef, [flush]),
            ok
    end.

persist_admission_accepted(#{run_id := RunId} = Task, Store, Deadline) ->
    try soma_event_store:by_run(
          Store, RunId, event_store_timeout(Deadline)) of
        Events when is_list(Events) ->
            Evidence = admission_evidence(Events, Task),
            case {maps:get(rejected, Evidence, false),
                  maps:get(accepted, Evidence, false)} of
                {true, _} -> {error, admission_rejected};
                {false, true} -> ok;
                {false, false} ->
                    soma_event_store:append(
                      Store, admission_accepted_event(Task),
                      event_store_timeout(Deadline))
            end
    catch
        _:_ -> {error, event_store_unavailable}
    end.

admission_accepted_event(
  #{task_id := TaskId, run_id := RunId,
    correlation_id := CorrelationId,
    admission_id := AdmissionId}) ->
    #{event_type => <<"cli.task.accepted">>,
      run_id => RunId,
      session_id => TaskId,
      task_id => TaskId,
      correlation_id => CorrelationId,
      payload => #{admission_protocol => cli_detached_v1,
                   admission_id => AdmissionId}}.

persist_admission_rejected(#{run_id := RunId} = Task, Store) ->
    try soma_event_store:by_run(
          Store, RunId, ?EVENT_STORE_CALL_TIMEOUT_MS) of
        Events when is_list(Events) ->
            case admission_decision(Events, Task) of
                rejected -> {ok, rejected};
                committed -> {ok, committed};
                pending ->
                    soma_event_store:append(
                      Store, admission_rejected_event(Task),
                      ?EVENT_STORE_CALL_TIMEOUT_MS),
                    {ok, rejected}
            end
    catch
        _:_ -> {error, event_store_unavailable}
    end.

admission_rejected_event(
  #{task_id := TaskId, run_id := RunId,
    correlation_id := CorrelationId,
    admission_id := AdmissionId}) ->
    #{event_type => <<"cli.task.admission_rejected">>,
      run_id => RunId,
      session_id => TaskId,
      task_id => TaskId,
      correlation_id => CorrelationId,
      payload => #{admission_protocol => cli_detached_v1,
                   admission_id => AdmissionId,
                   reason => owner_replaced_before_commit}}.

new_admission_id() ->
    crypto:strong_rand_bytes(16).

request_deadline() ->
    erlang:monotonic_time(millisecond) + ?REQUEST_BUDGET_MS.

request_expired(infinity) ->
    false;
request_expired(Deadline) ->
    remaining_request_ms(Deadline) =:= 0.

remaining_request_ms(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({run_completed, RunId, _Outputs}, State) ->
    {noreply, update_terminal_status(RunId, completed, State)};
handle_info({run_failed, RunId, _Reason}, State) ->
    {noreply, update_terminal_status(RunId, failed, State)};
handle_info({run_timeout, RunId}, State) ->
    {noreply, update_terminal_status(RunId, timeout, State)};
handle_info({run_cancelled, RunId}, State) ->
    {noreply, update_terminal_status(RunId, cancelled, State)};
handle_info({'DOWN', MRef, process, Owner, normal},
            #{admission_owner := Owner,
              admission_owner_mref := MRef} = State) ->
    %% Controlled stop retires this listener generation after its cancellation
    %% decisions are durable. A replacement rebuilds the projection and reloads
    %% the new tools directory from the event trail.
    {stop, normal, State};
handle_info({'DOWN', MRef, process, Owner, _Reason},
            #{admission_owner := Owner,
              admission_owner_mref := MRef} = State) ->
    %% An abnormal listener death retires the registry generation, matching
    %% the original linked ownership without a late-link noproc crash.
    {stop, normal, State};
handle_info({'DOWN', MRef, process, RunPid, Reason}, State) ->
    {noreply, handle_monitored_down(MRef, RunPid, Reason, State)};
handle_info({recover_detached_run, TaskId, RunId}, State) ->
    {noreply, retry_detached_recovery(TaskId, RunId, State)};
handle_info(recover_next_detached, State) ->
    {noreply, recover_next_queued_task(State)};
handle_info({persist_cancel_intent, TaskId}, State) ->
    {noreply, retry_cancel_intent(TaskId, State)};
handle_info({persist_admission_accept, TaskId}, State) ->
    {noreply, retry_admission_accept(TaskId, State)};
handle_info(persist_cancel_intents_batch, State) ->
    {noreply, retry_cancel_intents_batch(State)};
handle_info(recover_detached_tasks, State) ->
    {noreply, retry_full_recovery(State)};
handle_info({recovery_scan_result, Token, Worker, Store, Result}, State) ->
    {noreply, handle_recovery_scan_result(Token, Worker, Store, Result, State)};
handle_info({resume_start_barrier, TaskId, RunId, SupPid, Worker, Result},
            State) ->
    {noreply,
     handle_start_barrier_result(
       TaskId, RunId, SupPid, Worker, Result, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Linked workers do not die when this owner exits `normal'. Retire every
    %% blocked full-scan/barrier worker explicitly so controlled listener
    %% replacement cannot accumulate old-generation processes behind a
    %% suspended store or run supervisor.
    stop_owned_worker(maps:get(recovery_scan_worker, State, undefined)),
    maps:foreach(
      fun(_TaskId, Task) ->
              stop_owned_worker(maps:get(start_probe, Task, undefined))
      end, maps:get(tasks, State, #{})),
    ok.

stop_owned_worker(#{pid := Pid, mref := MRef}) when is_pid(Pid) ->
    unlink(Pid),
    demonitor_flush(MRef),
    exit(Pid, kill),
    ok;
stop_owned_worker(_Worker) ->
    ok.

code_change(_OldVsn, State0, _Extra) ->
    State1 = migrate_state(State0),
    _ = erlang:send_after(0, self(), recover_detached_tasks),
    {ok, State1#{recovery_scan_pending => true}}.

update_terminal_status(RunId, Status,
                       #{tasks := Tasks, runs := Runs,
                         monitors := Monitors} = State) ->
    case maps:find(RunId, Runs) of
        {ok, TaskId} ->
            case maps:find(TaskId, Tasks) of
                {ok, Task} ->
                    MRef = maps:get(mref, Task, undefined),
                    demonitor_flush(MRef),
                    TerminalTask = maps:without(
                                     [pid, mref, recovery_pending,
                                      cancel_requested],
                                     Task#{status => Status}),
                    State#{tasks := Tasks#{TaskId => TerminalTask},
                           runs := maps:remove(RunId, Runs),
                           monitors := maps:remove(MRef, Monitors)};
                error ->
                    State
            end;
        error ->
            State
    end.

%%% Durable detached-task recovery

recover_detached_candidates(Candidates, Store, State) ->
    {Indexed, NewQueueRev} = maps:fold(
                               fun(RunId, Task, {Acc, QueueAcc}) ->
                                       case known_run(RunId, Acc) of
                                           true -> {Acc, QueueAcc};
                                           false ->
                                               {index_detached_candidate(
                                                  Task, Acc),
                                                [{maps:get(task_id, Task),
                                                  RunId} | QueueAcc]}
                                       end
                               end, {State#{event_store => Store}, []},
                               Candidates),
    %% The authoritative candidate set is now completely represented in
    %% `tasks', so controlled stop may safely batch cancellation decisions.
    %% Actual adoption/resume is one message per task and never blocks this
    %% full-scan completion path for an unbounded candidate count.
    enqueue_recovery_candidates(
      lists:reverse(NewQueueRev),
      maps:remove(recovery_scan_pending, Indexed)).

index_detached_candidate(
  Task = #{task_id := TaskId, run_id := _RunId},
  #{tasks := Tasks} = State) ->
    State#{tasks :=
               Tasks#{TaskId => Task#{status => running,
                                      recovery_pending => true}}}.

enqueue_recovery_candidates([], State) ->
    State;
enqueue_recovery_candidates(New, State) ->
    Existing = maps:get(recovery_queue, State, []),
    case Existing of
        [] -> self() ! recover_next_detached;
        _ -> ok
    end,
    State#{recovery_queue => Existing ++ New}.

recover_next_queued_task(State) ->
    case maps:get(recovery_queue, State, []) of
        [{TaskId, RunId} | Rest] ->
            State0 = case Rest of
                         [] -> maps:remove(recovery_queue, State);
                         _ -> State#{recovery_queue => Rest}
                     end,
            State1 = retry_detached_recovery(TaskId, RunId, State0),
            case Rest of
                [] -> ok;
                _ -> self() ! recover_next_detached
            end,
            State1;
        [] ->
            maps:remove(recovery_queue, State)
    end.

%% One pass over the durable trail keeps only unfinished detached tasks.  The
%% final projection is bounded by live/interrupted tasks, not historical event
%% count.  Old journals have no run_origin and are intentionally ignored: after
%% their owner pid disappears they cannot safely be distinguished from a
%% foreground CLI request.
index_recovery_event(
  #{event_type := <<"run.started">>,
    run_id := RunId,
    session_id := EventSessionId,
    payload :=
        #{run_options :=
              #{run_origin := cli_detached,
                task_id := OptionTaskId} = RunOptions}} = Event,
  Candidates)
  when is_binary(OptionTaskId), is_binary(RunId) ->
    TaskId = case EventSessionId of
                 SessionId when is_binary(SessionId) -> SessionId;
                 _ -> OptionTaskId
             end,
    CorrelationId = maps:get(
                      correlation_id, RunOptions,
                      maps:get(correlation_id, Event, undefined)),
    AdmissionRequired =
        maps:get(admission_required, RunOptions, false) =:= true,
    AdmissionId = maps:get(admission_id, RunOptions, undefined),
    ValidIdentity = maps:get(run_id, RunOptions, undefined) =:= RunId
        andalso OptionTaskId =:= TaskId
        andalso maps:get(session_id, RunOptions, undefined) =:= TaskId
        andalso maps:get(correlation_id, Event, undefined) =:= CorrelationId
        andalso valid_admission_identity(AdmissionRequired, AdmissionId),
    Task0 = #{task_id => TaskId,
              run_id => RunId,
              correlation_id => CorrelationId,
              admission_required => AdmissionRequired,
              admission_id => AdmissionId,
              durable_cli_owner => true,
              status => running},
    Task = case ValidIdentity of
               true -> Task0;
               false -> Task0#{journal_invalid => true}
           end,
    maps:put(RunId, Task, Candidates);
index_recovery_event(
  #{event_type := <<"cli.task.accepted">>,
    run_id := RunId,
    task_id := TaskId,
    session_id := TaskId} = Event, Candidates)
  when is_binary(TaskId), is_binary(RunId) ->
    case maps:find(RunId, Candidates) of
        {ok, #{task_id := TaskId} = Task} ->
            case admission_event_matches_task(Event, Task) of
                true -> Candidates#{RunId => Task#{admission_accepted => true}};
                false -> Candidates
            end;
        _ ->
            Candidates
    end;
index_recovery_event(
  #{event_type := <<"run.admission.committed">>,
    run_id := RunId,
    session_id := TaskId} = Event, Candidates)
  when is_binary(TaskId), is_binary(RunId) ->
    update_admission_candidate(
      RunId, TaskId, Event, admission_committed, Candidates);
index_recovery_event(
  #{event_type := <<"cli.task.admission_rejected">>,
    run_id := RunId,
    task_id := TaskId,
    session_id := TaskId} = Event, Candidates)
  when is_binary(TaskId), is_binary(RunId) ->
    update_admission_candidate(
      RunId, TaskId, Event, admission_rejected, Candidates);
index_recovery_event(
  #{event_type := <<"cli.task.cancel_requested">>,
    run_id := RunId,
    task_id := TaskId,
    session_id := TaskId} = Event, Candidates)
  when is_binary(TaskId), is_binary(RunId) ->
    case maps:find(RunId, Candidates) of
        {ok, #{task_id := TaskId} = Task} ->
            case cancel_event_matches_task(Event, Task) of
                true ->
                    Candidates#{RunId =>
                                    Task#{cancel_requested => true,
                                          cancel_intent_durable => true}};
                false ->
                    Candidates
            end;
        _ ->
            Candidates
    end;
index_recovery_event(
  #{event_type := Type, run_id := RunId, session_id := SessionId},
  Candidates) ->
    case terminal_status(Type) of
        undefined -> Candidates;
        Status ->
            case maps:find(RunId, Candidates) of
                {ok, #{task_id := SessionId} = Task} ->
                    Candidates#{RunId => Task#{terminal_status => Status}};
                _ -> Candidates
            end
    end;
index_recovery_event(_Event, Candidates) ->
    Candidates.

recover_detached_task(RunId, Task, Store, State) ->
    %% A live-run adoption is only an in-memory ownership transition.  Exact
    %% admission authority remains in the durable trail, including a rejection
    %% append that may arrive after an earlier registry generation timed out.
    %% Refresh that authority before every interruption/recovery decision so a
    %% missing/stale in-memory field can never soften an admission-required run
    %% into the legacy path.
    case refresh_admission_state(RunId, Task, Store) of
        {ok, RefreshedTask} ->
            recover_detached_task_with_admission(
              RunId, RefreshedTask, Store, State);
        retry ->
            defer_recovery(Task, State)
    end.

recover_detached_task_with_admission(RunId, Task, Store, State) ->
    case {maps:get(journal_invalid, Task, false),
          maps:get(admission_required, Task, false),
          maps:get(admission_accepted, Task, false),
          maps:get(admission_committed, Task, false),
          maps:get(admission_rejected, Task, false)} of
        {true, _, _, _, _} ->
            recover_invalid_detached_task(RunId, Task, Store, State);
        {false, true, _, _, _} ->
            recover_pending_admission(Task, Store, State);
        {false, false, _, _, _} ->
            recover_valid_detached_task(RunId, Task, Store, State)
    end.

refresh_admission_state(RunId, Task, Store) ->
    case read_run_events(Store, RunId) of
        {ok, Events} ->
            Candidates = lists:foldl(fun index_recovery_event/2, #{}, Events),
            case maps:find(RunId, Candidates) of
                {ok, TrailTask} ->
                    AdmissionKeys =
                        [admission_required, admission_id,
                         admission_accepted, admission_committed,
                         admission_rejected, journal_invalid],
                    Cleared = maps:without(AdmissionKeys, Task),
                    {ok, maps:merge(
                           Cleared, maps:with(AdmissionKeys, TrailTask))};
                error ->
                    %% A task already selected for detached recovery without a
                    %% reconstructable marked start is malformed, not legacy
                    %% permission to resume.
                    {ok, Task#{journal_invalid => true}}
            end;
        retry ->
            retry
    end.

recover_pending_admission(Task = #{run_id := RunId}, Store, State) ->
    %% Compute the complete exact-identity decision on every pass. Accepted is
    %% only an edge intention; execution requires the run-owned commit too, and
    %% rejection is an absorbing tombstone independent of append order.
    case read_run_events(Store, RunId) of
        {ok, Events} ->
            case {latest_terminal_status(Events, Task),
                  admission_decision(Events, Task)} of
                {Status, _Decision} when Status =/= undefined ->
                    put_recovered_terminal_task(
                      Task, Status, undefined, State);
                {undefined, committed} ->
                    recover_valid_detached_task(
                      RunId,
                      Task#{admission_accepted => true,
                            admission_committed => true},
                      Store, State);
                {undefined, rejected} ->
                    recover_unaccepted_detached_task(
                      Task#{admission_rejected => true}, Store, State);
                {undefined, pending} ->
                    %% Persist the absorbing decision before killing a live
                    %% paused claim. An unacknowledged rejection remains
                    %% blocked/retried and can never become a late-accept race.
                    case persist_admission_rejected(Task, Store) of
                        {ok, rejected} ->
                            recover_unaccepted_detached_task(
                              Task#{admission_rejected => true}, Store, State);
                        {ok, committed} ->
                            recover_valid_detached_task(
                              RunId,
                              Task#{admission_accepted => true,
                                    admission_committed => true},
                              Store, State);
                        {error, _} ->
                            defer_recovery(
                              Task#{admission_reject_pending => true}, State)
                    end
            end;
        retry ->
            defer_recovery(Task, State)
    end.

recover_unaccepted_detached_task(Task = #{run_id := RunId}, Store, State) ->
    case find_live_run(RunId) of
        {ok, RunPid} ->
            %% The durable rejection is already present, so even a live paused
            %% claim has no execution authority. Kill it before terminalizing.
            exit(RunPid, kill),
            defer_recovery(Task, State);
        {error, not_found} ->
            cancel_after_supervisor_barrier(
              Task#{cancel_requested => true,
                    cancel_intent_durable => true}, Store, State);
        {error, {stale_run_generation, RunPid, _Old, _Current}} ->
            exit(RunPid, kill),
            defer_recovery(Task, State);
        {error, _Transient} ->
            defer_recovery(Task, State)
    end.

recover_invalid_detached_task(RunId, Task, Store, State) ->
    case find_live_run(RunId) of
        {ok, RunPid} ->
            %% A malformed durable owner record cannot coexist with a process
            %% that is still able to produce effects. Retire it first; only a
            %% later pass that proves absence may append the failed terminal.
            exit(RunPid, kill),
            defer_recovery(Task, State);
        {error, not_found} ->
            finalize_failed_task(
              Task, Store, invalid_run_started_journal, State);
        {error, {stale_run_generation, RunPid, _Old, _Current}} ->
            exit(RunPid, kill),
            defer_recovery(Task, State);
        {error, _Transient} ->
            defer_recovery(Task, State)
    end.

recover_valid_detached_task(RunId, Task, Store, State) ->
    case find_live_run(RunId) of
        {ok, RunPid} ->
            recover_live_run(Task, RunPid, Store, State);
        {error, not_found} ->
            recover_absent_task(Task, Store, State);
        {error, _AmbiguousOrTransient} ->
            defer_recovery(Task, State)
    end.

%% The initial all-events snapshot is a discovery index, not an execution
%% decision. Re-read this exact run after proving no live claim: an append whose
%% acknowledgement timed out in the previous registry generation is ordered
%% before this read and can still turn the decision into cancellation.
recover_absent_task(Task, Store, State) ->
    case maps:get(start_in_doubt, Task, undefined) of
        SupPid when is_pid(SupPid) ->
            case whereis(soma_run_sup) of
                SupPid -> wait_for_start_outcome(Task, SupPid, State);
                _Changed -> recover_absent_fresh(Task, Store, State)
            end;
        _ ->
            recover_absent_fresh(Task, Store, State)
    end.

recover_absent_fresh(Task, Store, State) ->
    case latest_recovery_state(Task, Store) of
        {terminal, Status} ->
            put_recovered_terminal_task(Task, Status, undefined, State);
        cancel_requested ->
            cancel_after_supervisor_barrier(
              Task#{cancel_requested => true,
                    cancel_intent_durable => true}, Store, State);
        resumable ->
            recover_resumable_decision(Task, Store, State);
        retry ->
            defer_recovery(Task, State)
    end.

cancel_after_supervisor_barrier(Task, Store, State) ->
    case whereis(soma_run_sup) of
        SupPid when is_pid(SupPid) ->
            case maps:get(start_barrier_complete, Task, undefined) of
                SupPid ->
                    %% The generation-bound which_children call was ordered
                    %% after every previously queued start_child request. The
                    %% caller reached this branch only after an exact index
                    %% lookup still proved absence, so no old in-doubt child
                    %% can appear behind the durable terminal.
                    finalize_cancelled_task(Task, Store, State);
                _NotDrained ->
                    wait_for_start_outcome(Task, SupPid, State)
            end;
        _ ->
            defer_recovery(Task, State)
    end.

recover_resumable_decision(
  #{cancel_requested := true, cancel_intent_durable := true} = Task,
  Store, State) ->
    finalize_cancelled_task(Task, Store, State);
recover_resumable_decision(
  #{cancel_requested := true} = Task, Store, State) ->
    %% A failed/unknown append stays sticky inside this VM. Persist it again;
    %% never reinterpret an in-memory owner decision as permission to resume.
    case persist_cancel_intent(Task, State) of
        {ok, State1} ->
            finalize_cancelled_task(
              Task#{cancel_intent_durable => true}, Store, State1);
        {error, _Reason, State1} ->
            defer_recovery(Task, State1)
    end;
recover_resumable_decision(Task, Store, State) ->
    resume_detached_task(maps:remove(start_in_doubt, Task), Store, State).

recover_live_run(Task, RunPid, Store, State) ->
    case adopt_owner(RunPid) of
        ok ->
            Recovered = put_recovered_running_task(Task, RunPid, State),
            case maps:get(cancel_requested, Task, false) of
                true -> ok;
                false -> ok = soma_run:activate(RunPid)
            end,
            Recovered;
        {error, {terminal, Status}} ->
            put_recovered_terminal_task(Task, Status, undefined, State);
        {error, not_found} ->
            %% The child can die between find_run/1 and adopt_owner/2.  Re-plan
            %% from the durable source of truth rather than leaving a stale
            %% running task in the registry.
            recover_absent_task(Task, Store, State);
        {error, {run_unresponsive, _Pid}} ->
            %% Timeout proves only that ownership is ambiguous, not that the
            %% child is absent. Keep the task visible and retry; never start a
            %% duplicate run while the old pid is alive.
            defer_recovery(Task, State)
    end.

resume_detached_task(Task = #{run_id := RunId}, Store, State) ->
    Result = try soma_run_resume_executor:resume(
                   RunId, self(), Store, ?EVENT_STORE_CALL_TIMEOUT_MS) of
                 ResumeResult -> ResumeResult
             catch
                 exit:_Reason -> retry
             end,
    case Result of
        {ok, RunPid} ->
            put_recovered_running_task(Task, RunPid, State);
        {terminal, Status} ->
            put_recovered_terminal_task(Task, Status, undefined, State);
        nothing_to_do ->
            %% Every step output is committed.  There is no work to repeat and
            %% the stable CLI task projection is completed even if the crash
            %% preceded run.completed by one event.
            put_recovered_terminal_task(Task, completed, undefined, State);
        {error, {resume_unsafe, _StepId} = Reason} ->
            put_recovered_terminal_task(Task, failed, Reason, State);
        {error, {resume_start_failed,
                 {run_supervisor_unresponsive, SupPid}}} when is_pid(SupPid) ->
            %% The start request may already be queued in this supervisor. One
            %% barrier worker observes its eventual outcome; retries only query
            %% the run index and never enqueue another start meanwhile.
            wait_for_start_outcome(Task, SupPid, State);
        {error, {resume_start_failed, _StartReason}} ->
            %% The plan was valid but the runtime generation changed before
            %% start_child completed. This is not durable task failure.
            defer_recovery(Task, State);
        {error, Reason} ->
            finalize_failed_task(Task, Store, Reason, State);
        retry ->
            defer_recovery(Task, State)
    end.

%% No live process owns this run and a durable CLI cancellation intent is on
%% the trail. Finalize the abandoned attempt directly: starting a resumed run
%% and cancelling it afterward would leave a window in which its first state
%% tool could execute. The terminal append is synchronous and idempotent across
%% crashes because the next scan sees `run.cancelled' and drops the candidate.
finalize_cancelled_task(Task, Store, State) ->
    case recorded_terminal(Task, Store) of
        {ok, undefined} ->
            case append_cancelled_terminal(Task, Store) of
                ok ->
                    put_recovered_terminal_task(
                      Task, cancelled, undefined, State);
                {error, _Reason} ->
                    defer_recovery(Task, State)
            end;
        {ok, Status} ->
            put_recovered_terminal_task(Task, Status, undefined, State);
        retry ->
            defer_recovery(Task, State)
    end.

finalize_failed_task(Task, Store, Reason, State) ->
    case recorded_terminal(Task, Store) of
        {ok, undefined} ->
            case append_failed_terminal(Task, Store) of
                ok ->
                    put_recovered_terminal_task(
                      Task, failed, {resume_failed, Reason}, State);
                {error, _AppendReason} ->
                    defer_recovery(Task, State)
            end;
        {ok, Status} ->
            put_recovered_terminal_task(Task, Status, undefined, State);
        retry ->
            defer_recovery(Task, State)
    end.

put_recovered_running_task(
  Task = #{task_id := TaskId,
           cancel_requested := true}, RunPid, State) ->
    State1 = put_running_task(Task, RunPid, State),
    State2 = case maps:get(cancel_intent_durable, Task, false) of
                 true -> mark_cancel_intent_durable(TaskId, State1);
                 false ->
                     _ = erlang:send_after(
                           ?RECOVERY_RETRY_MS, self(),
                           {persist_cancel_intent, TaskId}),
                     mark_cancel_requested(TaskId, State1)
             end,
    RunPid ! cancel,
    State2;
put_recovered_running_task(
  Task = #{task_id := _TaskId, correlation_id := _CorrId, run_id := _RunId},
  RunPid, State) ->
    put_running_task(Task, RunPid, State).

put_running_task(
  Task0 = #{task_id := TaskId, correlation_id := CorrId, run_id := RunId},
  RunPid, State) ->
    State1 = put_running_task(TaskId, CorrId, RunId, RunPid, State),
    #{tasks := Tasks} = State1,
    LiveTask = maps:get(TaskId, Tasks),
    %% Preserve the exact durable admission identity and decision carried by
    %% the recovery projection.  Runtime-local ownership fields come from the
    %% freshly installed live entry and cannot be injected by the journal.
    AdmissionKeys = [admission_required, admission_id,
                     admission_accepted, admission_committed,
                     admission_rejected],
    Preserved = maps:with(AdmissionKeys, Task0),
    State1#{tasks := Tasks#{TaskId => maps:merge(LiveTask, Preserved)}}.

put_running_task(TaskId, CorrId, RunId, RunPid,
                 #{tasks := Tasks, runs := Runs,
                   monitors := Monitors} = State) ->
    MRef = erlang:monitor(process, RunPid),
    Task = #{pid => RunPid,
             mref => MRef,
             task_id => TaskId,
             durable_cli_owner => true,
             status => running,
             correlation_id => CorrId,
             run_id => RunId},
    State#{tasks := Tasks#{TaskId => Task},
           runs := Runs#{RunId => TaskId},
           monitors := Monitors#{MRef => #{run_id => RunId,
                                          run_pid => RunPid}}}.

mark_cancel_requested(TaskId, #{tasks := Tasks} = State) ->
    Task = maps:get(TaskId, Tasks),
    State#{tasks := Tasks#{TaskId => Task#{cancel_requested => true}}}.

mark_cancel_intent_durable(TaskId, #{tasks := Tasks} = State) ->
    Task = maps:get(TaskId, Tasks),
    State#{tasks :=
               Tasks#{TaskId =>
                          Task#{cancel_requested => true,
                                cancel_intent_durable => true}}}.

mark_admission_accept_pending(TaskId, AdmissionId,
                              #{tasks := Tasks} = State) ->
    Task = maps:get(TaskId, Tasks),
    State#{tasks :=
               Tasks#{TaskId => Task#{admission_required => true,
                                      admission_id => AdmissionId,
                                      admission_accept_pending => true}}}.

mark_admission_accepted(TaskId, AdmissionId,
                        #{tasks := Tasks} = State) ->
    Task = maps:get(TaskId, Tasks),
    Accepted = maps:remove(
                 admission_accept_pending,
                 Task#{admission_required => true,
                       admission_id => AdmissionId,
                       admission_accepted => true}),
    State#{tasks := Tasks#{TaskId => Accepted}}.

mark_admission_activation_pending(TaskId, #{tasks := Tasks} = State) ->
    Task = maps:get(TaskId, Tasks),
    State#{tasks :=
               Tasks#{TaskId => Task#{admission_activation_pending => true}}}.

mark_admission_committed(TaskId, #{tasks := Tasks} = State) ->
    Task = maps:get(TaskId, Tasks),
    Committed = maps:remove(
                  admission_activation_pending,
                  maps:remove(
                    admission_accept_pending,
                    Task#{admission_accepted => true,
                          admission_committed => true})),
    State#{tasks := Tasks#{TaskId => Committed}}.

mark_admission_rejected(TaskId, #{tasks := Tasks} = State) ->
    Task = maps:get(TaskId, Tasks),
    Rejected = maps:without(
                 [admission_accept_pending, admission_activation_pending],
                 Task#{admission_rejected => true}),
    State#{tasks := Tasks#{TaskId => Rejected}}.

schedule_admission_accept_retry(TaskId) ->
    _ = erlang:send_after(
          ?RECOVERY_RETRY_MS, self(), {persist_admission_accept, TaskId}),
    ok.

retry_admission_accept(TaskId, #{tasks := Tasks} = State) ->
    case maps:find(TaskId, Tasks) of
        {ok, #{status := running, admission_required := true} = Task}
          when is_map_key(admission_accept_pending, Task);
               is_map_key(admission_activation_pending, Task) ->
            case runtime_event_store() of
                Store when is_pid(Store) ->
                    reconcile_pending_admission(TaskId, Task, Store, State);
                _ ->
                    schedule_admission_accept_retry(TaskId),
                    State
            end;
        _ ->
            State
    end.

reconcile_pending_admission(TaskId, Task, Store, State) ->
    case read_run_events(Store, maps:get(run_id, Task)) of
        {ok, Events} ->
            case admission_decision(Events, Task) of
                rejected ->
                    State1 = mark_admission_rejected(TaskId, State),
                    signal_cancel(TaskId, State1),
                    State1;
                committed ->
                    mark_admission_committed(TaskId, State);
                pending ->
                    continue_pending_admission(TaskId, Task, Store, State)
            end;
        retry ->
            schedule_admission_accept_retry(TaskId),
            State
    end.

continue_pending_admission(TaskId, Task, Store, State) ->
    case maps:get(admission_accept_pending, Task, false) of
        true ->
            case persist_admission_accepted(Task, Store, infinity) of
                ok ->
                    AdmissionId = maps:get(admission_id, Task),
                    State1 = mark_admission_accepted(
                               TaskId, AdmissionId, State),
                    State2 = mark_admission_activation_pending(
                               TaskId, State1),
                    signal_activate(TaskId, State2),
                    schedule_admission_accept_retry(TaskId),
                    State2;
                {error, admission_rejected} ->
                    State1 = mark_admission_rejected(TaskId, State),
                    signal_cancel(TaskId, State1),
                    State1;
                {error, _} ->
                    schedule_admission_accept_retry(TaskId),
                    State
            end;
        false ->
            %% Accepted is durable, but the run-owned commit acknowledgement is
            %% missing. Async activation is idempotent outside awaiting_start;
            %% re-read the trail before every retry so a rejection tombstone
            %% can never be crossed by a stale queued activation.
            signal_activate(TaskId, State),
            schedule_admission_accept_retry(TaskId),
            State
    end.

signal_activate(TaskId, #{tasks := Tasks}) ->
    case maps:find(TaskId, Tasks) of
        {ok, #{status := running, pid := RunPid}} ->
            soma_run:activate(RunPid);
        _ ->
            ok
    end.

put_recovered_terminal_task(
  #{task_id := TaskId, correlation_id := CorrId, run_id := RunId},
  Status, Reason, #{tasks := Tasks} = State) ->
    Base = #{status => Status,
             task_id => TaskId,
             correlation_id => CorrId,
             run_id => RunId},
    Task = case Reason of
               undefined -> Base;
               _ -> Base#{error => Reason}
           end,
    State#{tasks := Tasks#{TaskId => Task}}.

find_live_run(RunId) ->
    case whereis(soma_run_sup) of
        undefined -> {error, run_supervisor_transition};
        _Pid ->
            try soma_run_sup:find_run(
                  RunId, ?OWNER_CALL_TIMEOUT_MS) of
                Result -> Result
            catch
                exit:_Reason ->
                    %% The supervisor can change generation between whereis/1
                    %% and the lookup. Absence is not proven, so recovery must
                    %% defer instead of starting a duplicate run.
                    {error, run_supervisor_transition}
            end
    end.

adopt_owner(RunPid) ->
    try soma_run:adopt_owner(
          RunPid, self(), ?OWNER_CALL_TIMEOUT_MS) of
        Result -> Result
    catch
        exit:_Reason ->
            case is_process_alive(RunPid) of
                true -> {error, {run_unresponsive, RunPid}};
                false -> {error, not_found}
            end
    end.

handle_run_down(MRef, RunPid, _Reason,
                #{tasks := Tasks, runs := Runs,
                  monitors := Monitors} = State) ->
    case maps:take(MRef, Monitors) of
        {#{run_id := RunId, run_pid := RunPid}, RemainingMonitors} ->
            case maps:take(RunId, Runs) of
                {TaskId, RemainingRuns} ->
                    case maps:find(TaskId, Tasks) of
                        {ok, Task} ->
                            Interrupted = maps:without(
                                            [pid, mref, error],
                                            Task#{task_id => TaskId,
                                                  status => running}),
                            BaseState =
                                State#{runs := RemainingRuns,
                                       monitors := RemainingMonitors},
                            %% A DOWN without a terminal owner message is an
                            %% interruption, not a durable failure. Re-plan it
                            %% after the current/new runtime generation is
                            %% ready; this keeps runtime-only restarts and
                            %% unexpected run crashes monotonic.
                            defer_recovery(Interrupted, BaseState);
                        error ->
                            State#{runs := RemainingRuns,
                                   monitors := RemainingMonitors}
                    end;
                error ->
                    State#{monitors := RemainingMonitors}
            end;
        error ->
            State
    end.

runtime_event_store() ->
    %% The runtime-owned store has a stable local name. Recovery and stop must
    %% not call supervisor:which_children/1 because that API waits forever when
    %% soma_sup is suspended or synchronously shutting down children.
    whereis(soma_runtime_event_store).

retry_detached_recovery(TaskId, RunId, #{tasks := Tasks} = State) ->
    case maps:find(TaskId, Tasks) of
        {ok, #{run_id := RunId, status := running,
               recovery_pending := true} = Task} ->
            case recovery_runtime(State) of
                {ok, Store, ReadyState} ->
                    recover_detached_task(
                      RunId, maps:remove(recovery_pending, Task),
                      Store, ReadyState);
                retry ->
                    defer_recovery(Task, State)
            end;
        _Stale ->
            State
    end.

retry_cancel_intent(TaskId, #{tasks := Tasks} = State) ->
    case maps:find(TaskId, Tasks) of
        {ok, #{status := running,
               cancel_requested := true} = Task} ->
            case maps:get(cancel_intent_durable, Task, false) of
                true ->
                    State;
                false ->
                    case persist_cancel_intent(Task, State) of
                        {ok, State1} ->
                            State1;
                        {error, _Reason, State1} ->
                            _ = erlang:send_after(
                                  ?RECOVERY_RETRY_MS, self(),
                                  {persist_cancel_intent, TaskId}),
                            State1
                    end
            end;
        _TerminalOrMissing ->
            State
    end.

retry_cancel_intents_batch(#{tasks := Tasks} = State) ->
    Pending = [Task#{task_id => TaskId}
               || {TaskId,
                   #{status := running,
                     durable_cli_owner := true,
                     cancel_requested := true} = Task}
                      <- maps:to_list(Tasks),
                  not maps:get(cancel_intent_durable, Task, false)],
    case persist_cancel_intents(Pending, State) of
        {ok, State1} ->
            signal_requested_cancels(State1),
            State1;
        {error, _Reason, State1} ->
            _ = erlang:send_after(
                  ?EVENT_STORE_CALL_TIMEOUT_MS, self(),
                  persist_cancel_intents_batch),
            State1
    end.

retry_full_recovery(State) ->
    case recovery_runtime(State) of
        {ok, Store, ReadyState} ->
            start_full_recovery_scan(Store, ReadyState);
        retry ->
            schedule_full_recovery(State)
    end.

recovery_runtime(State) ->
    case runtime_running()
         andalso is_pid(whereis(soma_run_sup))
         andalso is_pid(whereis(soma_tool_registry)) of
        false ->
            retry;
        true ->
            case runtime_event_store() of
                undefined ->
                    retry;
                Store ->
                    ToolRegistry = whereis(soma_tool_registry),
                    case refresh_runtime_dependencies(
                           Store, ToolRegistry, State) of
                        {ok, ReadyState} -> {ok, Store, ReadyState};
                        retry -> retry
                    end
            end
    end.

refresh_runtime_dependencies(Store, ToolRegistry,
                             #{event_store := OldStore,
                               tool_registry := OldToolRegistry,
                               tools_dir := ToolsDir} = State) ->
    case ToolRegistry =:= OldToolRegistry of
        false ->
            case reload_config_tools(ToolsDir, ToolRegistry) of
                ok ->
                    {ok, State#{event_store => Store,
                                tool_registry => ToolRegistry}};
                retry ->
                    retry
            end;
        true when Store =/= OldStore ->
            {ok, State#{event_store => Store}};
        true ->
            {ok, State}
    end.

reload_config_tools(ToolsDir, ToolRegistry)
  when is_list(ToolsDir); is_binary(ToolsDir) ->
    try soma_tool_config:load_dir(ToolsDir) of
        _Result -> stable_tool_registry(ToolRegistry)
    catch
        _:_ -> retry
    end;
reload_config_tools(_ToolsDir, ToolRegistry) ->
    stable_tool_registry(ToolRegistry).

stable_tool_registry(ToolRegistry) ->
    case whereis(soma_tool_registry) of
        ToolRegistry when is_pid(ToolRegistry) -> ok;
        _Changed -> retry
    end.

runtime_running() ->
    lists:keymember(soma_runtime, 1, application:which_applications()).

defer_recovery(
  Task = #{task_id := TaskId, run_id := RunId},
  #{tasks := Tasks} = State) ->
    Deferred = maps:without(
                 [pid, mref, error],
                 Task#{status => running, recovery_pending => true}),
    _ = erlang:send_after(
          ?RECOVERY_RETRY_MS, self(),
          {recover_detached_run, TaskId, RunId}),
    State#{tasks := Tasks#{TaskId => Deferred}}.

schedule_full_recovery(#{recovery_scan_pending := true} = State) ->
    case maps:is_key(recovery_scan_worker, State) of
        true -> State;
        false ->
            _ = erlang:send_after(
                  ?RECOVERY_RETRY_MS, self(), recover_detached_tasks),
            State
    end;
schedule_full_recovery(State) ->
    _ = erlang:send_after(
          ?RECOVERY_RETRY_MS, self(), recover_detached_tasks),
    State#{recovery_scan_pending => true}.

start_full_recovery_scan(_Store,
                         #{recovery_scan_worker := _Worker} = State) ->
    State;
start_full_recovery_scan(Store, State) ->
    Parent = self(),
    Token = make_ref(),
    {Worker, MRef} =
        spawn_opt(
          fun() ->
                  Result = try soma_event_store:all(Store) of
                               Events when is_list(Events) ->
                                   Indexed = lists:foldl(
                                               fun index_recovery_event/2,
                                               #{}, Events),
                                   {ok, unfinished_candidates(Indexed)}
                           catch
                               Class:Reason -> {error, {Class, Reason}}
                           end,
                  Parent ! {recovery_scan_result, Token, self(), Store,
                            Result}
          end, [link, monitor]),
    State#{recovery_scan_pending => true,
           recovery_scan_worker => #{pid => Worker, mref => MRef,
                                     token => Token, store => Store}}.

handle_recovery_scan_result(
  Token, Worker, Store, {ok, Candidates},
  #{recovery_scan_worker :=
        #{pid := Worker, mref := MRef, token := Token, store := Store}} = State) ->
    unlink(Worker),
    erlang:demonitor(MRef, [flush]),
    Cleared = clear_recovery_scan_worker(State),
    case recovery_runtime(Cleared) of
        {ok, Store, ReadyState} ->
            recover_detached_candidates(Candidates, Store, ReadyState);
        _GenerationChanged ->
            schedule_full_recovery(Cleared)
    end;
handle_recovery_scan_result(
  Token, Worker, Store, {error, _Reason},
  #{recovery_scan_worker :=
        #{pid := Worker, mref := MRef, token := Token, store := Store}} = State) ->
    unlink(Worker),
    erlang:demonitor(MRef, [flush]),
    schedule_full_recovery(clear_recovery_scan_worker(State));
handle_recovery_scan_result(_Token, _Worker, _Store, _Result, State) ->
    State.

clear_recovery_scan_worker(State) ->
    maps:remove(recovery_scan_worker, State).

unfinished_candidates(Candidates) ->
    maps:filter(
      fun(_RunId, Task) ->
              maps:get(terminal_status, Task, undefined) =:= undefined
      end, Candidates).

latest_recovery_state(#{run_id := RunId} = Task, Store) ->
    case read_run_events(Store, RunId) of
        {ok, Events} ->
            case latest_terminal_status(Events, Task) of
                undefined ->
                    case lists:any(
                           fun(Event) ->
                                   cancel_event_matches_task(Event, Task)
                           end, Events) of
                        true -> cancel_requested;
                        false -> resumable
                    end;
                Status ->
                    {terminal, Status}
            end;
        retry ->
            retry
    end.

latest_terminal_status(Events, Task) ->
    lists:foldl(
      fun(Event, Acc) ->
              case terminal_event_status(Event, Task) of
                  undefined -> Acc;
                  Status -> Status
              end
      end, undefined, Events).

wait_for_start_outcome(
  Task = #{task_id := TaskId, run_id := RunId}, SupPid,
  #{tasks := Tasks} = State) ->
    case maps:get(start_probe, Task, undefined) of
        #{pid := Probe} when is_pid(Probe) ->
            State;
        _ ->
            Parent = self(),
            {Probe, MRef} =
                spawn_opt(
                  fun() ->
                          Result = try supervisor:which_children(SupPid) of
                                       _Children -> ok
                                   catch
                                       Class:Reason -> {error, {Class, Reason}}
                                   end,
                          Parent ! {resume_start_barrier, TaskId, RunId,
                                    SupPid, self(), Result}
                  end, [link, monitor]),
            Waiting = maps:without(
                        [pid, mref, error],
                        Task#{status => running,
                              recovery_pending => true,
                              start_in_doubt => SupPid,
                              start_probe => #{pid => Probe,
                                               mref => MRef,
                                               supervisor => SupPid}}),
            State#{tasks := Tasks#{TaskId => Waiting}}
    end.

handle_start_barrier_result(
  TaskId, RunId, SupPid, Worker, Result, #{tasks := Tasks} = State) ->
    case maps:find(TaskId, Tasks) of
        {ok, #{run_id := RunId,
               start_probe := #{pid := Worker, mref := MRef,
                                 supervisor := SupPid}} = Task} ->
            unlink(Worker),
            erlang:demonitor(MRef, [flush]),
            Cleared = maps:without([start_probe, start_in_doubt], Task),
            Drained = case {Result, whereis(soma_run_sup)} of
                          {ok, SupPid} ->
                              Cleared#{start_barrier_complete => SupPid};
                          _ ->
                              maps:remove(start_barrier_complete, Cleared)
                      end,
            defer_recovery(Drained,
                           State#{tasks := Tasks#{TaskId => Drained}});
        _Stale ->
            State
    end.

handle_monitored_down(MRef, Pid, Reason, State) ->
    case maps:get(recovery_scan_worker, State, undefined) of
        #{pid := Pid, mref := MRef} ->
            schedule_full_recovery(clear_recovery_scan_worker(State));
        _ ->
            case start_probe_task(MRef, Pid, State) of
                {ok, TaskId, Task, State1} ->
                    Cleared = maps:without(
                                [start_probe, start_in_doubt], Task),
                    defer_recovery(Cleared,
                                   put_task(TaskId, Cleared, State1));
                not_found ->
                    handle_run_down(MRef, Pid, Reason, State)
            end
    end.

start_probe_task(MRef, Pid, #{tasks := Tasks} = State) ->
    case [{TaskId, Task}
          || {TaskId,
              #{start_probe := #{pid := Probe, mref := ProbeMRef}} = Task}
                 <- maps:to_list(Tasks),
             Probe =:= Pid, ProbeMRef =:= MRef] of
        [{TaskId, Task}] -> {ok, TaskId, Task, State};
        [] -> not_found
    end.

put_task(TaskId, Task, #{tasks := Tasks} = State) ->
    State#{tasks := Tasks#{TaskId => Task}}.

replace_admission_owner(State, Owner) ->
    OldOwner = maps:get(admission_owner, State, undefined),
    %% The first listener created this registry through start_link/1. From the
    %% first successful bind onward ownership is monitor-only, so a later live
    %% rebind cannot retain a stale link to the old listener generation.
    maybe_unlink(OldOwner),
    maybe_unlink(Owner),
    demonitor_flush(maps:get(admission_owner_mref, State, undefined)),
    State#{admission_owner => Owner,
           admission_owner_mref => erlang:monitor(process, Owner)}.

maybe_unlink(Pid) when is_pid(Pid) ->
    unlink(Pid),
    ok;
maybe_unlink(_Pid) ->
    ok.

update_admission_tools_dir(keep_tools_dir, State) ->
    State;
update_admission_tools_dir({replace_tools_dir, ToolsDir}, State) ->
    State#{tools_dir => ToolsDir,
           %% Force the next recovery pass to verify/reload this exact
           %% directory into the current tool-registry generation.
           tool_registry => undefined}.

migrate_state(State0) ->
    Tasks0 = maps:get(tasks, State0, #{}),
    maps:foreach(
      fun(_TaskId, Task) ->
              demonitor_flush(maps:get(mref, Task, undefined))
      end, Tasks0),
    {Tasks, Runs, Monitors} =
        maps:fold(
          fun(TaskId, #{status := running, pid := RunPid} = Task,
              {TaskAcc, RunAcc, MonitorAcc}) when is_pid(RunPid) ->
                  MRef = erlang:monitor(process, RunPid),
                  RunId = maps:get(run_id, Task, undefined),
                  {TaskAcc#{TaskId => Task#{mref => MRef}},
                   case RunId of
                       undefined -> RunAcc;
                       _ -> RunAcc#{RunId => TaskId}
                   end,
                   MonitorAcc#{MRef => #{run_id => RunId,
                                         run_pid => RunPid}}};
             (TaskId, Task, {TaskAcc, RunAcc, MonitorAcc}) ->
                  {TaskAcc#{TaskId => maps:remove(mref, Task)},
                   RunAcc, MonitorAcc}
          end, {#{}, #{}, #{}}, Tasks0),
    Owner = maps:get(admission_owner, State0, undefined),
    demonitor_flush(maps:get(admission_owner_mref, State0, undefined)),
    OwnerMRef = case Owner of
                    Pid when is_pid(Pid) ->
                        unlink(Pid),
                        erlang:monitor(process, Pid);
                    _ -> undefined
                end,
    Base = #{tasks => Tasks,
             runs => Runs,
             monitors => Monitors,
             tools_dir => maps:get(tools_dir, State0, undefined),
             event_store => runtime_event_store(),
             tool_registry => undefined,
             admission_owner => Owner,
             admission_owner_mref => OwnerMRef},
    case maps:get(admission_closed, State0, false) of
        true -> Base#{admission_closed => true};
        false -> Base
    end.

known_run(RunId, #{runs := Runs, tasks := Tasks}) ->
    maps:is_key(RunId, Runs)
        orelse lists:any(
                 fun(#{run_id := TaskRunId}) -> TaskRunId =:= RunId;
                    (_Task) -> false
                 end, maps:values(Tasks)).

terminal_status(<<"run.completed">>) -> completed;
terminal_status(<<"run.failed">>) -> failed;
terminal_status(<<"run.timeout">>) -> timeout;
terminal_status(<<"run.cancelled">>) -> cancelled;
terminal_status(_Type) -> undefined.

demonitor_flush(MRef) when is_reference(MRef) ->
    erlang:demonitor(MRef, [flush]),
    ok;
demonitor_flush(_MRef) ->
    ok.

%%% Durable owner cancellation

persist_cancel_intents(Tasks, State) ->
    persist_cancel_intents(Tasks, State, infinity).

persist_cancel_intents(Tasks, State, Deadline) ->
    Requested = lists:foldl(
                  fun(#{task_id := TaskId}, Acc) ->
                          mark_cancel_requested(TaskId, Acc)
                  end, State, Tasks),
    Durable = [Task || #{durable_cli_owner := true} = Task <- Tasks,
                       not maps:get(cancel_intent_durable, Task, false)],
    case Durable of
        [] ->
            {ok, Requested};
        _ ->
            persist_cancel_intent_batch(Durable, Requested, Deadline)
    end.

persist_cancel_intent_batch(Tasks, State, Deadline) ->
    case runtime_event_store() of
        Store when is_pid(Store) ->
            try read_cancel_snapshot(Store, Deadline) of
                Events when is_list(Events) ->
                    Recorded = recorded_cancel_identities(Events),
                    Missing = [Task || Task <- Tasks,
                                       not maps:is_key(
                                             cancel_intent_identity(Task),
                                             Recorded)],
                    NewEvents = [cancel_intent_event(Task)
                                 || Task <- Missing],
                    case append_cancel_intent_batch(
                           Store, NewEvents, Deadline) of
                        ok ->
                            DurableState = lists:foldl(
                                             fun(#{task_id := TaskId}, Acc) ->
                                                     mark_cancel_intent_durable(
                                                       TaskId, Acc)
                                             end, State, Tasks),
                            {ok, DurableState#{event_store => Store}};
                        {error, _Reason} ->
                            {error, cancel_intent_not_persisted,
                             State#{event_store => Store}}
                    end
            catch
                _:_ ->
                    {error, cancel_intent_not_persisted,
                     State#{event_store => Store}}
            end;
        _ ->
            {error, cancel_intent_not_persisted, State}
    end.

append_cancel_intent_batch(_Store, [], _Deadline) ->
    ok;
append_cancel_intent_batch(Store, Events, Deadline) ->
    try soma_event_store:append_many(
          Store, Events, event_store_timeout(Deadline)) of
        ok -> ok
    catch
        _:_ -> {error, event_store_unavailable}
    end.

read_cancel_snapshot(Store, Deadline) ->
    soma_event_store:all(Store, event_store_timeout(Deadline)).

event_store_timeout(infinity) ->
    ?EVENT_STORE_CALL_TIMEOUT_MS;
event_store_timeout(Deadline) ->
    case remaining_request_ms(Deadline) of
        0 -> exit(request_expired);
        Remaining -> erlang:min(?EVENT_STORE_CALL_TIMEOUT_MS, Remaining)
    end.

recorded_cancel_identities(Events) ->
    lists:foldl(
      fun(#{event_type := <<"cli.task.cancel_requested">>,
            run_id := RunId,
            task_id := TaskId,
            session_id := TaskId} = Event, Acc)
            when is_binary(RunId), is_binary(TaskId) ->
              CorrelationId = maps:get(correlation_id, Event, undefined),
              Acc#{{RunId, TaskId, TaskId, CorrelationId} => true};
         (_Event, Acc) ->
              Acc
      end, #{}, Events).

cancel_intent_identity(
  #{run_id := RunId, task_id := TaskId} = Task) ->
    {RunId, TaskId, TaskId, maps:get(correlation_id, Task, undefined)}.

persist_cancel_intent(#{cancel_intent_durable := true}, State) ->
    {ok, State};
persist_cancel_intent(
  #{task_id := TaskId, run_id := RunId,
    durable_cli_owner := true} = Task, State)
  when is_binary(RunId) ->
    case runtime_event_store() of
        Store when is_pid(Store) ->
            Event = cancel_intent_event(Task),
            case cancel_intent_recorded(Task, Store) of
                {ok, true} ->
                    {ok, mark_cancel_intent_durable(
                           TaskId, State#{event_store => Store})};
                {ok, false} ->
                    try soma_event_store:append(
                          Store, Event, ?EVENT_STORE_CALL_TIMEOUT_MS) of
                        ok ->
                            {ok, mark_cancel_intent_durable(
                                   TaskId, State#{event_store => Store})}
                    catch
                        _Class:_Reason ->
                            {error, cancel_intent_not_persisted,
                             mark_cancel_requested(
                               TaskId, State#{event_store => Store})}
                    end;
                retry ->
                    {error, cancel_intent_not_persisted,
                     mark_cancel_requested(
                       TaskId, State#{event_store => Store})}
            end;
        _ ->
            {error, cancel_intent_not_persisted,
             mark_cancel_requested(TaskId, State)}
    end;
%% Compatibility for entries installed through the older public register/2
%% API. They have no durable run journal to recover, so a bare live-pid cancel
%% remains sufficient and cannot create a post-restart replay candidate.
persist_cancel_intent(#{task_id := TaskId}, State) ->
    {ok, mark_cancel_requested(TaskId, State)}.

signal_cancel(TaskId, #{tasks := Tasks}) ->
    case maps:find(TaskId, Tasks) of
        {ok, #{status := running, pid := RunPid}} -> RunPid ! cancel;
        _ -> ok
    end.

signal_requested_cancels(#{tasks := Tasks} = State) ->
    maps:foreach(
      fun(TaskId, #{status := running, cancel_requested := true}) ->
              signal_cancel(TaskId, State);
         (_TaskId, _Task) ->
              ok
      end, Tasks).

schedule_pending_cancel_intents(#{tasks := Tasks}) ->
    case lists:any(
           fun(#{status := running,
                 durable_cli_owner := true,
                 cancel_requested := true} = Task) ->
                   not maps:get(cancel_intent_durable, Task, false);
              (_Task) -> false
           end, maps:values(Tasks)) of
        true ->
            _ = erlang:send_after(
                  ?RECOVERY_RETRY_MS, self(), persist_cancel_intents_batch),
            ok;
        false ->
            ok
    end.

schedule_cancel_intent_retry(TaskId) ->
    _ = erlang:send_after(
          ?RECOVERY_RETRY_MS, self(), {persist_cancel_intent, TaskId}),
    ok.

cancel_intent_event(
  #{task_id := TaskId, run_id := RunId} = Task) ->
    Event0 = #{event_type => <<"cli.task.cancel_requested">>,
               run_id => RunId,
               session_id => TaskId,
               task_id => TaskId,
               payload => #{reason => cli_cancel}},
    with_optional(correlation_id,
                  maps:get(correlation_id, Task, undefined), Event0).

append_cancelled_terminal(Task, Store) ->
    Event0 = #{event_type => <<"run.cancelled">>,
               run_id => maps:get(run_id, Task),
               session_id => maps:get(task_id, Task),
               task_id => maps:get(task_id, Task),
               payload => #{reason => cli_cancel_recovered}},
    Event = with_optional(
              correlation_id,
              maps:get(correlation_id, Task, undefined),
              Event0),
    try soma_event_store:append(
          Store, Event, ?EVENT_STORE_CALL_TIMEOUT_MS) of
        ok -> ok
    catch
        _Class:_Reason -> {error, event_store_unavailable}
    end.

append_failed_terminal(Task, Store) ->
    Event0 = #{event_type => <<"run.failed">>,
               run_id => maps:get(run_id, Task),
               session_id => maps:get(task_id, Task),
               task_id => maps:get(task_id, Task),
               payload => #{reason => cli_resume_failed}},
    Event = with_optional(
              correlation_id,
              maps:get(correlation_id, Task, undefined),
              Event0),
    try soma_event_store:append(
          Store, Event, ?EVENT_STORE_CALL_TIMEOUT_MS) of
        ok -> ok
    catch
        _Class:_Reason -> {error, event_store_unavailable}
    end.

with_optional(_Key, undefined, Map) -> Map;
with_optional(Key, Value, Map) -> Map#{Key => Value}.

cancel_intent_recorded(
  #{run_id := RunId} = Task, Store) ->
    case read_run_events(Store, RunId) of
        {ok, Events} ->
            {ok, lists:any(
                   fun(Event) -> cancel_event_matches_task(Event, Task)
                   end, Events)};
        retry ->
            retry
    end.

admission_event_matches_task(Event, Task) ->
    admission_marker_matches(
      <<"cli.task.accepted">>, Event, Task).

admission_commit_matches_task(Event, Task) ->
    admission_marker_matches(
      <<"run.admission.committed">>, Event, Task).

admission_rejection_matches_task(Event, Task) ->
    admission_marker_matches(
      <<"cli.task.admission_rejected">>, Event, Task).

admission_marker_matches(
  Type,
  #{event_type := Type,
    run_id := RunId,
    task_id := TaskId,
    session_id := TaskId,
    payload := #{admission_protocol := cli_detached_v1,
                 admission_id := AdmissionId}} = Event,
  #{run_id := RunId, task_id := TaskId,
    admission_id := AdmissionId} = Task)
  when is_binary(AdmissionId), byte_size(AdmissionId) > 0 ->
    maps:get(correlation_id, Event, undefined) =:=
        maps:get(correlation_id, Task, undefined);
admission_marker_matches(_Type, _Event, _Task) ->
    false.

admission_evidence(Events, Task) ->
    lists:foldl(
      fun(Event, Evidence) ->
              case admission_rejection_matches_task(Event, Task) of
                  true ->
                      Evidence#{rejected => true};
                  false ->
                      advance_admission_evidence(Event, Task, Evidence)
              end
      end, #{}, Events).

advance_admission_evidence(Event, Task, Evidence) ->
    case run_start_matches_admission(Event, Task) of
        true ->
            Evidence#{started => true};
        false ->
            case {maps:get(started, Evidence, false),
                  admission_event_matches_task(Event, Task),
                  admission_commit_matches_task(Event, Task)} of
                {true, true, _} ->
                    Evidence#{accepted => true};
                {true, _, true} ->
                    case maps:get(accepted, Evidence, false) of
                        true -> Evidence#{committed => true};
                        false -> Evidence
                    end;
                _ ->
                    Evidence
            end
    end.

run_start_matches_admission(
  #{event_type := <<"run.started">>,
    run_id := RunId,
    session_id := TaskId,
    payload := #{run_options :=
                     #{run_id := RunId,
                       run_origin := cli_detached,
                       task_id := TaskId,
                       session_id := TaskId,
                       admission_required := true,
                       admission_id := AdmissionId}}} = Event,
  #{run_id := RunId, task_id := TaskId,
    admission_id := AdmissionId} = Task)
  when is_binary(AdmissionId), byte_size(AdmissionId) > 0 ->
    maps:get(correlation_id, Event, undefined) =:=
        maps:get(correlation_id, Task, undefined);
run_start_matches_admission(_Event, _Task) ->
    false.

admission_decision(Events, Task) ->
    Evidence = admission_evidence(Events, Task),
    case {maps:get(rejected, Evidence, false),
          maps:get(accepted, Evidence, false),
          maps:get(committed, Evidence, false)} of
        {true, _, _} -> rejected;
        {false, true, true} -> committed;
        _ -> pending
    end.

update_admission_candidate(RunId, TaskId, Event, Flag, Candidates) ->
    case maps:find(RunId, Candidates) of
        {ok, #{task_id := TaskId} = Task} ->
            Matches = case Flag of
                          admission_committed ->
                              admission_commit_matches_task(Event, Task);
                          admission_rejected ->
                              admission_rejection_matches_task(Event, Task)
                      end,
            case Matches of
                true -> Candidates#{RunId => Task#{Flag => true}};
                false -> Candidates
            end;
        _ ->
            Candidates
    end.

valid_admission_identity(false, _AdmissionId) ->
    true;
valid_admission_identity(true, AdmissionId) ->
    is_binary(AdmissionId) andalso byte_size(AdmissionId) > 0.

cancel_event_matches_task(
  #{event_type := <<"cli.task.cancel_requested">>,
    run_id := RunId,
    task_id := TaskId,
    session_id := TaskId} = Event,
  #{run_id := RunId, task_id := TaskId} = Task) ->
    maps:get(correlation_id, Event, undefined) =:=
        maps:get(correlation_id, Task, undefined);
cancel_event_matches_task(_Event, _Task) ->
    false.

recorded_terminal(#{run_id := RunId} = Task, Store) ->
    case read_run_events(Store, RunId) of
        {ok, Events} ->
            {ok, lists:foldl(
                   fun(Event, Acc) ->
                           case terminal_event_status(Event, Task) of
                               undefined -> Acc;
                               Status -> Status
                           end
                   end, undefined, Events)};
        retry ->
            retry
    end.

terminal_event_status(
  #{event_type := Type, session_id := TaskId},
  #{task_id := TaskId}) ->
    terminal_status(Type);
terminal_event_status(_Event, _Task) ->
    undefined.

read_run_events(Store, RunId) ->
    try soma_event_store:by_run(
          Store, RunId, ?EVENT_STORE_CALL_TIMEOUT_MS) of
        Events when is_list(Events) -> {ok, Events}
    catch
        _Class:_Reason -> retry
    end.
