%% @doc Supervised owner for already-decided service invocations. The service
%% normalizes an invoke envelope, admits its canonical steps through the
%% configured policy, and owns the resulting `soma_run' monitor and task view.
-module(soma_service).

-behaviour(gen_server).

-define(DEFAULT_RESULT_INLINE_BYTES, 16384).

-export([start_link/0]).
-export([invoke/1, status/1, result/1, watch/3, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {event_store,
                policy = #{allowed_tools => []},
                result_inline_bytes = ?DEFAULT_RESULT_INLINE_BYTES,
                data_dir,
                tasks = #{},
                requests = #{},
                runs = #{},
                monitors = #{},
                cleanup_monitors = #{}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

invoke(Envelope) ->
    gen_server:call(?MODULE, {invoke, Envelope}).

status(TaskId) ->
    gen_server:call(?MODULE, {status, TaskId}).

result(TaskId) ->
    gen_server:call(?MODULE, {result, TaskId}).

watch(TaskId, Cursor, Limit) ->
    gen_server:call(?MODULE, {watch, TaskId, Cursor, Limit}).

cancel(TaskId) ->
    gen_server:call(?MODULE, {cancel, TaskId}).

init([]) ->
    Policy = application:get_env(
               soma_actor, service_policy,
               #{allowed_tools => []}),
    InlineBytes = configured_result_inline_bytes(),
    DataDir = configured_service_data_dir(),
    State = #state{event_store = runtime_event_store(),
                   policy = Policy,
                   result_inline_bytes = InlineBytes,
                   data_dir = DataDir},
    {ok, rebuild_dedupe_index(State)}.

handle_call({invoke, Envelope}, _From, State) ->
    case soma_service_envelope:normalize(Envelope) of
        {ok, Normalized} ->
            invoke_normalized(Normalized, State);
        {error, _Diagnostics} = Error ->
            {reply, Error, State}
    end;
handle_call({status, TaskId}, _From, State = #state{tasks = Tasks}) ->
    Reply = case maps:find(TaskId, Tasks) of
                {ok, Task} -> {ok, public_task(Task)};
                error -> {error, not_found}
            end,
    {reply, Reply, State};
handle_call({result, TaskId}, _From,
            State = #state{tasks = Tasks,
                           result_inline_bytes = InlineBytes,
                           data_dir = DataDir}) ->
    Reply = task_result(
              maps:get(TaskId, Tasks, undefined), InlineBytes, DataDir),
    {reply, Reply, State};
handle_call({watch, TaskId, Cursor, Limit}, _From,
            State = #state{event_store = EventStore, tasks = Tasks}) ->
    Reply = task_watch(
              maps:get(TaskId, Tasks, undefined),
              Cursor, Limit, EventStore),
    {reply, Reply, State};
handle_call({cancel, TaskId}, _From, State) ->
    cancel_task(TaskId, State);
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({run_completed, RunId, Outputs}, State) ->
    {noreply,
     finish_run(RunId, {completed, Outputs}, State)};
handle_info({run_failed, RunId, _Reason}, State) ->
    {noreply,
     finish_run(RunId, #{status => failed, reason => run_failed}, State)};
handle_info({run_timeout, RunId}, State) ->
    {noreply,
     finish_run(RunId, #{status => failed, reason => timeout}, State)};
handle_info({run_cancelled, RunId}, State) ->
    {noreply, finish_run(RunId, #{status => cancelled}, State)};
handle_info({timeout, TRef, {task_deadline, TaskId, RunId}}, State) ->
    {noreply, expire_deadline(TRef, TaskId, RunId, State)};
handle_info({'DOWN', MRef, process, Pid, _Reason}, State) ->
    {noreply, handle_process_down(MRef, Pid, State)};
handle_info(_Info, State) ->
    {noreply, State}.

configured_result_inline_bytes() ->
    case application:get_env(
           soma_actor, service_result_inline_bytes,
           ?DEFAULT_RESULT_INLINE_BYTES) of
        InlineBytes when is_integer(InlineBytes), InlineBytes > 0 ->
            InlineBytes;
        _Invalid ->
            ?DEFAULT_RESULT_INLINE_BYTES
    end.

configured_service_data_dir() ->
    case application:get_env(soma_actor, service_data_dir) of
        {ok, DataDir} when is_binary(DataDir) ->
            binary_to_list(DataDir);
        {ok, DataDir} when is_list(DataDir) ->
            DataDir;
        _MissingOrInvalid ->
            default_service_data_dir()
    end.

default_service_data_dir() ->
    Home = case os:getenv("HOME") of
               false -> ".";
               HomeDir -> HomeDir
           end,
    filename:join([Home, ".soma", "data"]).

task_result(undefined, _InlineBytes, _DataDir) ->
    {error, not_found};
task_result(#{status := succeeded,
              task_id := TaskId,
              result := Output}, InlineBytes, DataDir) ->
    soma_service_artifact:present(TaskId, Output, InlineBytes, DataDir);
task_result(#{status := accepted}, _InlineBytes, _DataDir) ->
    {error, not_ready};
task_result(#{status := running}, _InlineBytes, _DataDir) ->
    {error, not_ready};
task_result(_Terminal, _InlineBytes, _DataDir) ->
    {error, result_unavailable}.

task_watch(undefined, _Cursor, _Limit, _EventStore) ->
    {error, not_found};
task_watch(#{correlation_id := CorrelationId}, undefined, Limit, EventStore)
  when is_integer(Limit), Limit > 0, is_pid(EventStore) ->
    Events = soma_event_store:by_correlation(EventStore, CorrelationId),
    {ok, #{events => lists:sublist(Events, Limit), cursor => undefined}};
task_watch(_Task, _Cursor, _Limit, _EventStore) ->
    {error, invalid_watch}.

invoke_normalized(Envelope,
                  State = #state{requests = Requests, tasks = Tasks}) ->
    RequestId = maps:get(request_id, Envelope),
    EnvelopeHash = envelope_hash(Envelope),
    case maps:get(RequestId, Requests, undefined) of
        #{envelope_hash := EnvelopeHash} = Request ->
            {reply, duplicate_reply(Request, Tasks), State};
        undefined ->
            start_invocation(Envelope, EnvelopeHash, State);
        #{envelope_hash := _DifferentHash} ->
            {reply, {error, request_id_conflict}, State}
    end.

start_invocation(Envelope, EnvelopeHash,
                 State = #state{event_store = EventStore,
                                policy = ConfiguredPolicy,
                                tasks = Tasks,
                                requests = Requests}) ->
    Steps = operation_steps(maps:get(operation, Envelope)),
    TaskId = mint_id("service-task-"),
    RunId = mint_id("service-run-"),
    RequestId = maps:get(request_id, Envelope),
    CorrelationId = maps:get(correlation_id, Envelope, TaskId),
    Handle = #{task_id => TaskId,
               request_id => RequestId,
               status => accepted},
    Task0 = #{task_id => TaskId,
              request_id => RequestId,
              envelope_hash => EnvelopeHash,
              status => accepted,
              run_id => RunId,
              correlation_id => CorrelationId},
    Task = maybe_add_deadline(
             Envelope, maybe_add_max_output_bytes(Envelope, Task0)),
    Request = #{envelope_hash => EnvelopeHash,
                task_id => TaskId,
                accepted_handle => Handle},
    ok = emit_service_task(EventStore, <<"service.task.accepted">>,
                           Task, accepted_event_payload(Task)),
    AdmittedState =
        State#state{tasks = maps:put(TaskId, Task, Tasks),
                    requests = maps:put(RequestId, Request, Requests)},
    Proposal = #{kind => run_steps, steps => Steps},
    Policy = invocation_policy(Envelope, ConfiguredPolicy),
    case soma_policy:check(Proposal, Policy) of
        allow ->
            start_allowed_invocation(
              Steps, Task, Handle, AdmittedState);
        {reject, Reason} ->
            reject_invocation(Reason, Task, AdmittedState)
    end.

start_allowed_invocation(Steps, Task, Handle,
                         State = #state{event_store = EventStore,
                                        tasks = Tasks,
                                        runs = Runs,
                                        monitors = Monitors}) ->
    TaskId = maps:get(task_id, Task),
    RunId = maps:get(run_id, Task),
    RequestId = maps:get(request_id, Task),
    EnvelopeHash = maps:get(envelope_hash, Task),
    RunOpts0 = #{run_id => RunId,
                 task_id => TaskId,
                 request_id => RequestId,
                 envelope_hash => EnvelopeHash,
                 auto_resume => false,
                 session_pid => self(),
                 event_store => EventStore,
                 steps => Steps},
    RunOpts1 = maps:merge(
                 RunOpts0,
                 maps:with(
                   [max_output_bytes, deadline_at_ms], Task)),
    RunOpts = RunOpts1#{correlation_id =>
                            maps:get(correlation_id, Task)},
    case soma_run_sup:start_run(RunOpts) of
        {ok, RunPid} ->
            MRef = erlang:monitor(process, RunPid),
            RunningTask0 = Task#{status => running,
                                 run_pid => RunPid,
                                 run_mref => MRef},
            RunningTask = arm_deadline(RunningTask0),
            ok = emit_service_task(EventStore, <<"service.task.running">>,
                                   RunningTask,
                                   accepted_event_payload(RunningTask)),
            NewState =
                State#state{
                  tasks = maps:put(TaskId, RunningTask, Tasks),
                  runs = maps:put(RunId, TaskId, Runs),
                  monitors = maps:put(
                               MRef,
                               #{run_id => RunId, run_pid => RunPid},
                               Monitors)},
            {reply, {ok, Handle}, NewState};
        {error, _Reason} ->
            Terminal = Task#{status => failed, reason => run_start_failed},
            ok = emit_service_task(EventStore, <<"service.task.terminal">>,
                                   Terminal,
                                   terminal_event_payload(Terminal)),
            NewState = State#state{
                         tasks = maps:put(TaskId, Terminal, Tasks)},
            {reply, {ok, public_task(Terminal)}, NewState}
    end.

reject_invocation(Reason, Task,
                  State = #state{event_store = EventStore,
                                 tasks = Tasks}) ->
    Rejection = {policy_rejected, bounded_policy_reason(Reason)},
    Terminal = Task#{status => rejected, reason => Rejection},
    ok = emit_service_task(EventStore, <<"service.task.terminal">>,
                           Terminal, terminal_event_payload(Terminal)),
    TaskId = maps:get(task_id, Task),
    NewState = State#state{tasks = maps:put(TaskId, Terminal, Tasks)},
    {reply, {ok, public_task(Terminal)}, NewState}.

%% Rejection detail must not grow with the plan: a policy reason carries one
%% list entry per rejected step, so a large all-disallowed plan would inflate
%% the public task and the durable terminal event. Collapse to the distinct
%% disallowed tools, capped at a fixed count.
bounded_policy_reason({tools_not_allowed, Tools}) ->
    {tools_not_allowed, lists:sublist(lists:usort(Tools), 8)}.

duplicate_reply(#{task_id := TaskId,
                  accepted_handle := Handle}, Tasks) ->
    Task = maps:get(TaskId, Tasks),
    case maps:get(status, Task) of
        running -> {ok, Handle};
        _Terminal -> {ok, public_task(Task)}
    end.

envelope_hash(Envelope) ->
    crypto:hash(sha256, term_to_binary(Envelope, [deterministic])).

operation_steps(#{kind := tool, step := Step}) ->
    [Step];
operation_steps(#{kind := steps, steps := Steps}) ->
    Steps.

invocation_policy(#{scope := Scope}, _ConfiguredPolicy) ->
    #{allowed_tools => projected_scope_tools(Scope)};
invocation_policy(_Envelope, ConfiguredPolicy) ->
    ConfiguredPolicy.

projected_scope_tools(Scope) ->
    [Name || #{name := Name} <- soma_tool_registry:list_tools(),
             lists:member(atom_to_binary(Name, utf8), Scope)].

finish_run(RunId, Terminal,
           State = #state{tasks = Tasks,
                          runs = Runs,
                          monitors = Monitors,
                          event_store = EventStore}) ->
    case maps:take(RunId, Runs) of
        error ->
            State;
        {TaskId, NewRuns} ->
            Task = maps:get(TaskId, Tasks),
            RunPid = maps:get(run_pid, Task),
            MRef = maps:get(run_mref, Task),
            cancel_deadline(Task),
            erlang:demonitor(MRef, [flush]),
            terminate_run_child(RunPid),
            Task1 = maps:merge(
                      maps:without(
                        [run_pid, run_mref, deadline_tref,
                         deadline_expired, cancel_requested],
                        Task),
                      terminal_for_task(Terminal, Task)),
            ok = emit_service_task(EventStore, <<"service.task.terminal">>,
                                   Task1, terminal_event_payload(Task1)),
            State#state{
              tasks = maps:put(TaskId, Task1, Tasks),
              runs = NewRuns,
              monitors = maps:remove(MRef, Monitors)}
    end.

terminal_for_task(_Terminal, #{deadline_expired := true}) ->
    #{status => failed, reason => deadline_exceeded};
terminal_for_task(_Terminal, #{cancel_requested := true}) ->
    #{status => cancelled};
terminal_for_task({completed, Outputs}, Task) ->
    case maps:find(max_output_bytes, Task) of
        {ok, MaxOutputBytes} ->
            case erlang:external_size(Outputs) > MaxOutputBytes of
                true ->
                    #{status => failed,
                      reason => max_output_bytes_exceeded};
                false ->
                    #{status => succeeded, result => Outputs}
            end;
        error ->
            #{status => succeeded, result => Outputs}
    end;
terminal_for_task(Terminal, _Task) ->
    Terminal.

maybe_add_max_output_bytes(Envelope, Task) ->
    case maps:find(max_output_bytes, Envelope) of
        {ok, MaxOutputBytes} ->
            Task#{max_output_bytes => MaxOutputBytes};
        error ->
            Task
    end.

maybe_add_deadline(Envelope, Task) ->
    case maps:find(deadline_ms, Envelope) of
        {ok, DeadlineMs} ->
            Task#{deadline_at_ms =>
                      erlang:system_time(millisecond) + DeadlineMs};
        error ->
            Task
    end.

arm_deadline(#{deadline_at_ms := DeadlineAtMs,
               task_id := TaskId,
               run_id := RunId} = Task) ->
    RemainingMs = max(
                    0,
                    DeadlineAtMs - erlang:system_time(millisecond)),
    TRef = erlang:start_timer(
             RemainingMs, self(), {task_deadline, TaskId, RunId}),
    Task#{deadline_tref => TRef};
arm_deadline(Task) ->
    Task.

expire_deadline(TRef, TaskId, RunId,
                State = #state{event_store = EventStore,
                               tasks = Tasks}) ->
    case maps:get(TaskId, Tasks, undefined) of
        #{status := running,
          run_id := RunId,
          run_pid := RunPid,
          deadline_tref := TRef} = Task ->
            ExpiredTask = maps:remove(
                            deadline_tref,
                            Task#{deadline_expired => true}),
            ok = emit_service_task(
                   EventStore, <<"service.task.deadline_expired">>,
                   ExpiredTask, #{}),
            RunPid ! cancel,
            State#state{tasks = maps:put(TaskId, ExpiredTask, Tasks)};
        _StaleOrTerminal ->
            State
    end.

cancel_task(TaskId,
            State = #state{event_store = EventStore,
                           tasks = Tasks}) ->
    case maps:get(TaskId, Tasks, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        #{status := running, run_pid := RunPid} = Task ->
            cancel_deadline(Task),
            CancellingTask = maps:remove(
                               deadline_tref,
                               Task#{cancel_requested => true}),
            ok = emit_service_task(
                   EventStore, <<"service.task.cancel_requested">>,
                   CancellingTask, #{}),
            RunPid ! cancel,
            {reply, ok,
             State#state{tasks = maps:put(
                                   TaskId, CancellingTask, Tasks)}};
        _NotRunning ->
            {reply, {error, not_running}, State}
    end.

cancel_deadline(#{deadline_tref := TRef}) ->
    _ = erlang:cancel_timer(TRef, [{async, false}, {info, false}]),
    ok;
cancel_deadline(_Task) ->
    ok.

terminate_run_child(RunPid) ->
    _ = supervisor:terminate_child(soma_run_sup, RunPid),
    ok.

handle_process_down(MRef, Pid,
                    State = #state{cleanup_monitors = CleanupMonitors,
                                   monitors = Monitors}) ->
    case maps:take(MRef, CleanupMonitors) of
        {#{run_id := RunId,
           worker_pid := Pid,
           terminal := Terminal}, NewCleanupMonitors} ->
            finish_run(
              RunId, Terminal,
              State#state{cleanup_monitors = NewCleanupMonitors});
        error ->
            case maps:get(MRef, Monitors, undefined) of
                #{run_id := RunId, run_pid := Pid} ->
                    await_invocation_cleanup(
                      RunId, MRef,
                      #{status => failed, reason => run_crashed}, State);
                _StaleMonitor ->
                    State
            end
    end.

%% A run can be killed before its normal cancel path executes. Its linked tool
%% worker is already exiting, but a CLI worker first tears down its port child.
%% Keep the public task running until that worker confirms its own death, so a
%% terminal service task never exposes live invocation resources.
await_invocation_cleanup(
  RunId, RunMRef, Terminal,
  State = #state{event_store = EventStore,
                 tasks = Tasks,
                 runs = Runs,
                 monitors = Monitors,
                 cleanup_monitors = CleanupMonitors}) ->
    case active_tool_worker(EventStore, RunId) of
        WorkerPid when is_pid(WorkerPid) ->
            CleanupMRef = erlang:monitor(process, WorkerPid),
            TaskId = maps:get(RunId, Runs),
            Task = maps:get(TaskId, Tasks),
            cancel_deadline(Task),
            WaitingTask = maps:remove(deadline_tref, Task),
            State#state{
              tasks = maps:put(TaskId, WaitingTask, Tasks),
              monitors = maps:remove(RunMRef, Monitors),
              cleanup_monitors = maps:put(
                                   CleanupMRef,
                                   #{run_id => RunId,
                                     worker_pid => WorkerPid,
                                     terminal => Terminal},
                                   CleanupMonitors)};
        undefined ->
            finish_run(RunId, Terminal, State)
    end.

active_tool_worker(undefined, _RunId) ->
    undefined;
active_tool_worker(EventStore, RunId) ->
    Candidate =
        lists:foldl(
          fun(#{event_type := <<"tool.started">>,
                tool_call_pid := WorkerPid}, _Acc)
                when is_pid(WorkerPid) ->
                  WorkerPid;
             (_Event, Acc) ->
                  Acc
          end,
          undefined,
          soma_event_store:by_run(EventStore, RunId)),
    case Candidate of
        WorkerPid when is_pid(WorkerPid) ->
            case is_process_alive(WorkerPid) of
                true -> WorkerPid;
                false -> undefined
            end;
        undefined ->
            undefined
    end.

public_task(#{status := accepted} = Task) ->
    lifecycle_task(Task);
public_task(#{status := running} = Task) ->
    lifecycle_task(Task);
public_task(Task) ->
    Lifecycle = lifecycle_task(Task),
    Summary = bounded_terminal_summary(terminal_summary(Task)),
    Lifecycle#{summary => Summary}.

lifecycle_task(Task) ->
    maps:with([task_id, request_id, status], Task).

terminal_summary(#{status := succeeded, result := Result}) ->
    #{result_bytes =>
          byte_size(term_to_binary(Result, [deterministic]))};
terminal_summary(#{status := cancelled}) ->
    #{reason_class => cancelled};
terminal_summary(#{reason := Reason}) ->
    #{reason_class => reason_class(Reason)};
terminal_summary(_Task) ->
    #{reason_class => failed}.

bounded_terminal_summary(Summary) ->
    case byte_size(term_to_binary(Summary, [deterministic])) =< 512 of
        true -> Summary;
        false -> #{reason_class => failed}
    end.

reason_class(run_failed) -> run_failed;
reason_class(timeout) -> timeout;
reason_class(run_start_failed) -> run_start_failed;
reason_class(deadline_exceeded) -> deadline_exceeded;
reason_class(max_output_bytes_exceeded) -> max_output_bytes_exceeded;
reason_class(run_crashed) -> run_crashed;
reason_class(service_result_reconstruction_failed) ->
    service_result_reconstruction_failed;
reason_class(service_interrupted_before_start) ->
    service_interrupted_before_start;
reason_class(service_recovery_failed) -> service_recovery_failed;
reason_class(resume_start_failed) -> resume_start_failed;
reason_class({policy_rejected, _Reason}) -> policy_rejected;
reason_class({resume_unsafe, _StepId}) -> resume_unsafe;
reason_class(_Unknown) -> failed.

%% Rebuild the request-id index from the bounded service lifecycle trail. The
%% event store is the source of truth; task and request maps are only the live
%% cache owned by this service process.
rebuild_dedupe_index(State = #state{event_store = undefined}) ->
    State;
rebuild_dedupe_index(State = #state{event_store = EventStore}) ->
    Events = soma_event_store:all(EventStore),
    Replay = finalize_replay_index(
               lists:foldl(
                 fun index_replay_event/2, empty_replay_index(), Events)),
    lists:foldl(
      fun(Event, Acc) -> recover_accepted_task(Event, Replay, Acc) end,
      State,
      maps:get(accepted, Replay)).

empty_replay_index() ->
    #{accepted_rev => [],
      terminals => #{},
      owner_decisions => #{},
      run_trails_rev => #{}}.

index_replay_event(Event, Replay0) ->
    Replay1 = index_service_event(Event, Replay0),
    case maps:get(run_id, Event, undefined) of
        undefined ->
            Replay1;
        RunId ->
            Trails = maps:get(run_trails_rev, Replay1),
            Trail = maps:get(RunId, Trails, []),
            Replay1#{run_trails_rev := maps:put(
                                           RunId, [Event | Trail], Trails)}
    end.

index_service_event(
  #{event_type := <<"service.task.accepted">>} = Event,
  Replay = #{accepted_rev := Accepted}) ->
    Replay#{accepted_rev := [Event | Accepted]};
index_service_event(
  #{event_type := <<"service.task.terminal">>, task_id := TaskId} = Event,
  Replay = #{terminals := Terminals})
  when TaskId =/= undefined ->
    Replay#{terminals := maps:put(TaskId, Event, Terminals)};
index_service_event(
  #{event_type := <<"service.task.deadline_expired">>, task_id := TaskId},
  Replay)
  when TaskId =/= undefined ->
    index_owner_decision(TaskId, deadline_expired, Replay);
index_service_event(
  #{event_type := <<"service.task.cancel_requested">>, task_id := TaskId},
  Replay)
  when TaskId =/= undefined ->
    index_owner_decision(TaskId, cancel_requested, Replay);
index_service_event(_Event, Replay) ->
    Replay.

index_owner_decision(
  TaskId, Decision,
  Replay = #{owner_decisions := OwnerDecisions}) ->
    Decisions = maps:get(TaskId, OwnerDecisions, #{}),
    Replay#{owner_decisions := maps:put(
                                  TaskId, Decisions#{Decision => true},
                                  OwnerDecisions)}.

finalize_replay_index(
  Replay = #{accepted_rev := AcceptedRev,
             run_trails_rev := RunTrailsRev}) ->
    RunTrails = maps:map(
                  fun(_RunId, TrailRev) -> lists:reverse(TrailRev) end,
                  RunTrailsRev),
    maps:without(
      [accepted_rev, run_trails_rev],
      Replay#{accepted => lists:reverse(AcceptedRev),
              run_trails => RunTrails}).

recover_accepted_task(Event, Replay, State) ->
    case accepted_task(Event) of
        {ok, Task0, Request} ->
            Task = restore_owner_decisions(Task0, Replay),
            TaskId = maps:get(task_id, Task),
            RunId = maps:get(run_id, Task),
            Trail = maps:get(
                      RunId, maps:get(run_trails, Replay), []),
            case maps:find(TaskId, maps:get(terminals, Replay)) of
                {ok, TerminalEvent} ->
                    recover_recorded_terminal(
                      Task, Request, TerminalEvent, Trail, State);
                error ->
                    recover_unfinished_task(Task, Request, Trail, State)
            end;
        error ->
            State
    end.

restore_owner_decisions(
  Task, #{owner_decisions := OwnerDecisions}) ->
    maps:merge(
      Task, maps:get(maps:get(task_id, Task), OwnerDecisions, #{})).

accepted_task(#{task_id := TaskId,
                request_id := RequestId,
                run_id := RunId,
                payload := #{envelope_hash := EnvelopeHash} = Payload} = Event) ->
    CorrelationId = maps:get(correlation_id, Event, TaskId),
    Handle = #{task_id => TaskId,
               request_id => RequestId,
               status => accepted},
    Task0 = #{task_id => TaskId,
              request_id => RequestId,
              run_id => RunId,
              correlation_id => CorrelationId,
              envelope_hash => EnvelopeHash,
              status => running},
    Task = restore_service_budgets(Payload, Task0),
    Request = #{envelope_hash => EnvelopeHash,
                task_id => TaskId,
                accepted_handle => Handle},
    {ok, Task, Request};
accepted_task(_Event) ->
    error.

recover_recorded_terminal(Task, Request, TerminalEvent, Trail, State) ->
    case owner_decision_terminal(Task) of
        {ok, OwnerTerminal} ->
            recover_recorded_owner_terminal(
              OwnerTerminal, Request, TerminalEvent, State);
        none ->
            recover_recorded_run_terminal(
              Task, Request, TerminalEvent, Trail, State)
    end.

recover_recorded_owner_terminal(
  OwnerTerminal, Request, #{payload := Payload}, State) ->
    case maps:with([status, reason], Payload) =:=
         terminal_event_payload(OwnerTerminal) of
        true ->
            put_terminal_task(OwnerTerminal, Request, State);
        false ->
            record_recovered_terminal(OwnerTerminal, Request, State)
    end.

recover_recorded_run_terminal(
  Task, Request, #{payload := #{status := succeeded}}, Trail, State) ->
    case reconstructed_success(Task, Trail) of
        {ok, Recovered} -> put_terminal_task(Recovered, Request, State);
        error -> put_terminal_task(
                   Task#{status => failed,
                         reason => service_result_reconstruction_failed},
                   Request, State)
    end;
recover_recorded_run_terminal(
  Task, Request, #{payload := Payload}, _Trail, State) ->
    Status = maps:get(status, Payload, failed),
    Terminal0 = Task#{status => Status},
    Terminal = case maps:find(reason, Payload) of
                   {ok, Reason} -> Terminal0#{reason => Reason};
                   error -> Terminal0
               end,
    put_terminal_task(Terminal, Request, State).

recover_unfinished_task(Task, Request, Trail, State) ->
    case recovery_deadline_decision(Task, Trail) of
        continue ->
            recover_unfinished_before_deadline(Task, Request, Trail, State);
        Decision ->
            land_recovery_deadline(Decision, Task, Request, State)
    end.

recover_unfinished_before_deadline(Task, Request, Trail, State) ->
    RunId = maps:get(run_id, Task),
    case soma_run_sup:find_run(RunId) of
        {ok, RunPid} ->
            case soma_run:adopt_owner(RunPid, self()) of
                ok ->
                    monitor_recovered_run(Task, Request, RunPid, State);
                {error, {terminal, _Status}} ->
                    terminate_run_child(RunPid),
                    recover_from_run_trail(
                      Task, Request, current_run_trail(Task, State), State)
            end;
        {error, not_found} ->
            recover_from_run_trail_before_deadline(
              Task, Request, Trail, State)
    end.

monitor_recovered_run(Task, Request, RunPid,
                      State = #state{tasks = Tasks,
                                     requests = Requests,
                                     runs = Runs,
                                     monitors = Monitors}) ->
    MRef = erlang:monitor(process, RunPid),
    RunId = maps:get(run_id, Task),
    TaskId = maps:get(task_id, Task),
    Running0 = Task#{status => running,
                     run_pid => RunPid,
                     run_mref => MRef},
    Running = arm_recovered_deadline(Running0),
    NewState = State#state{
                 tasks = maps:put(TaskId, Running, Tasks),
                 requests = maps:put(
                              maps:get(request_id, Task), Request, Requests),
                 runs = maps:put(RunId, TaskId, Runs),
                 monitors = maps:put(MRef,
                                     #{run_id => RunId, run_pid => RunPid},
                                     Monitors)},
    enforce_recovered_owner_decision(Running),
    NewState.

arm_recovered_deadline(#{deadline_expired := true} = Task) ->
    maps:remove(deadline_tref, Task);
arm_recovered_deadline(#{cancel_requested := true} = Task) ->
    maps:remove(deadline_tref, Task);
arm_recovered_deadline(Task) ->
    arm_deadline(Task).

enforce_recovered_owner_decision(
  #{deadline_expired := true, run_pid := RunPid}) ->
    RunPid ! cancel,
    ok;
enforce_recovered_owner_decision(
  #{cancel_requested := true, run_pid := RunPid}) ->
    RunPid ! cancel,
    ok;
enforce_recovered_owner_decision(_Task) ->
    ok.

recover_from_run_trail(Task, Request, Trail, State) ->
    case recovery_deadline_decision(Task, Trail) of
        continue ->
            recover_from_run_trail_before_deadline(
              Task, Request, Trail, State);
        Decision ->
            land_recovery_deadline(Decision, Task, Request, State)
    end.

recover_from_run_trail_before_deadline(Task, Request, Trail, State) ->
    case reconstructed_terminal(Task, Trail) of
        {ok, Terminal} ->
            record_recovered_terminal(Terminal, Request, State);
        error ->
            recover_nonterminal_run(Task, Request, Trail, State)
    end.

recover_nonterminal_run(Task, Request, Trail,
                        State = #state{event_store = EventStore}) ->
    RunId = maps:get(run_id, Task),
    case soma_run_resume_plan:plan(Trail, RunId) of
        {unsafe, StepId} ->
            InDoubt = Task#{status => in_doubt,
                            reason => {resume_unsafe, StepId}},
            record_recovered_terminal(InDoubt, Request, State);
        {resume, _Plan} ->
            recover_resume_result(
              soma_run_resume_executor:resume(
                RunId, self(), EventStore),
              Task, Request, Trail, State);
        nothing_to_do ->
            recover_committed_outputs(Task, Request, Trail, State);
        {terminal, _Status} ->
            recover_current_terminal(Task, Request, Trail, State);
        {error, no_run_started_journal} ->
            fail_recovery(
              Task, Request, service_interrupted_before_start, State);
        {error, _Reason} ->
            fail_recovery(Task, Request, service_recovery_failed, State)
    end.

recover_resume_result({ok, RunPid}, Task, Request, _Trail, State) ->
    monitor_recovered_run(Task, Request, RunPid, State);
recover_resume_result(nothing_to_do, Task, Request, Trail, State) ->
    recover_committed_outputs(Task, Request, Trail, State);
recover_resume_result({terminal, _Status}, Task, Request, _Trail, State) ->
    recover_current_terminal(
      Task, Request, current_run_trail(Task, State), State);
recover_resume_result(_Unrecoverable, Task, Request, _Trail, State) ->
    fail_recovery(Task, Request, resume_start_failed, State).

recover_current_terminal(Task, Request, Trail, State) ->
    recover_from_run_trail(Task, Request, Trail, State).

recover_committed_outputs(Task, Request, Trail, State) ->
    case soma_run_resume:reconstruct_events(Trail) of
        {ok, #{next_step := undefined, outputs := Outputs}} ->
            Terminal = maps:merge(
                         Task,
                         terminal_for_task({completed, Outputs}, Task)),
            record_recovered_terminal(Terminal, Request, State);
        _Unrecoverable ->
            fail_recovery(Task, Request, service_recovery_failed, State)
    end.

fail_recovery(Task, Request, Reason, State) ->
    record_recovered_terminal(
      Task#{status => failed, reason => Reason}, Request, State).

recovery_deadline_decision(#{deadline_expired := true}, _Trail) ->
    continue;
recovery_deadline_decision(#{cancel_requested := true}, _Trail) ->
    continue;
recovery_deadline_decision(Task, Trail) ->
    case maps:find(deadline_at_ms, Task) of
        error ->
            continue;
        {ok, DeadlineAtMs} when is_integer(DeadlineAtMs), DeadlineAtMs > 0 ->
            classify_recovery_deadline(DeadlineAtMs, Trail);
        {ok, _InvalidDeadline} ->
            invalid
    end.

classify_recovery_deadline(DeadlineAtMs, Trail) ->
    case durable_outcome_timestamp(Trail) of
        {ok, TimestampNs} when is_integer(TimestampNs) ->
            case TimestampNs > DeadlineAtMs * 1000000 of
                true -> expired;
                false -> continue
            end;
        none ->
            RemainingMs = DeadlineAtMs - erlang:system_time(millisecond),
            case RemainingMs =< 0 of
                true -> expired;
                false ->
                    case soma_service_envelope:timer_safe_ms(RemainingMs) of
                        true -> continue;
                        false -> invalid
                    end
            end
    end.

durable_outcome_timestamp(Trail) ->
    case soma_run_resume:reconstruct_events(Trail) of
        {ok, #{terminal_status := Status}} when Status =/= undefined ->
            last_event_timestamp(Trail, fun is_terminal_run_event/1);
        {ok, #{next_step := undefined}} ->
            last_event_timestamp(
              Trail,
              fun(#{event_type := <<"step.succeeded">>}) -> true;
                 (_Event) -> false
              end);
        _ ->
            none
    end.

last_event_timestamp(Trail, Predicate) ->
    lists:foldl(
      fun(Event, Acc) ->
              case Predicate(Event) of
                  true ->
                      case maps:get(timestamp, Event, undefined) of
                          Timestamp when is_integer(Timestamp) ->
                              {ok, Timestamp};
                          _InvalidTimestamp ->
                              Acc
                      end;
                  false ->
                      Acc
              end
      end,
      none,
      Trail).

is_terminal_run_event(#{event_type := Type}) ->
    Type =:= <<"run.completed">> orelse
        Type =:= <<"run.failed">> orelse
        Type =:= <<"run.timeout">> orelse
        Type =:= <<"run.cancelled">>;
is_terminal_run_event(_Event) ->
    false.

land_recovery_deadline(expired, Task, Request, State) ->
    terminate_recovered_run(Task),
    Expired = Task#{deadline_expired => true,
                    status => failed,
                    reason => deadline_exceeded},
    ok = emit_service_task(
           State#state.event_store,
           <<"service.task.deadline_expired">>, Expired, #{}),
    record_recovered_terminal(Expired, Request, State);
land_recovery_deadline(invalid, Task, Request, State) ->
    terminate_recovered_run(Task),
    fail_recovery(Task, Request, service_recovery_failed, State).

terminate_recovered_run(#{run_id := RunId}) ->
    case soma_run_sup:find_run(RunId) of
        {ok, RunPid} -> terminate_run_child(RunPid);
        {error, not_found} -> ok
    end.

record_recovered_terminal(
  Terminal, Request, State = #state{event_store = EventStore}) ->
    ok = emit_service_task(EventStore, <<"service.task.terminal">>,
                           Terminal, terminal_event_payload(Terminal)),
    put_terminal_task(Terminal, Request, State).

reconstructed_terminal(Task, Trail) ->
    case owner_decision_terminal(Task) of
        {ok, Terminal} ->
            {ok, Terminal};
        none ->
            reconstructed_run_terminal(Task, Trail)
    end.

reconstructed_run_terminal(Task, Trail) ->
    case soma_run_resume:reconstruct_events(Trail) of
        {ok, #{terminal_status := completed, outputs := Outputs}} ->
            {ok, maps:merge(Task, terminal_for_task(
                                    {completed, Outputs}, Task))};
        {ok, #{terminal_status := failed}} ->
            {ok, Task#{status => failed, reason => run_failed}};
        {ok, #{terminal_status := timeout}} ->
            {ok, Task#{status => failed, reason => timeout}};
        {ok, #{terminal_status := cancelled}} ->
            {ok, Task#{status => cancelled}};
        _ ->
            error
    end.

reconstructed_success(Task, Trail) ->
    case soma_run_resume:reconstruct_events(Trail) of
        {ok, #{terminal_status := completed, outputs := Outputs}} ->
            {ok, maps:merge(
                   Task, terminal_for_task({completed, Outputs}, Task))};
        {ok, #{terminal_status := undefined,
               next_step := undefined,
               outputs := Outputs}} ->
            {ok, maps:merge(
                   Task, terminal_for_task({completed, Outputs}, Task))};
        _ ->
            error
    end.

owner_decision_terminal(#{deadline_expired := true} = Task) ->
    {ok, Task#{status => failed, reason => deadline_exceeded}};
owner_decision_terminal(#{cancel_requested := true} = Task) ->
    {ok, maps:remove(reason, Task#{status => cancelled})};
owner_decision_terminal(_Task) ->
    none.

current_run_trail(#{run_id := RunId},
                  #state{event_store = EventStore}) ->
    soma_event_store:by_run(EventStore, RunId).

put_terminal_task(Task, Request,
                  State = #state{tasks = Tasks, requests = Requests}) ->
    TaskId = maps:get(task_id, Task),
    RequestId = maps:get(request_id, Task),
    State#state{tasks = maps:put(TaskId, Task, Tasks),
                requests = maps:put(RequestId, Request, Requests)}.

restore_service_budgets(Payload, Task) ->
    maps:merge(
      Task,
      maps:with([max_output_bytes, deadline_at_ms], Payload)).

accepted_event_payload(Task) ->
    maps:with([envelope_hash, max_output_bytes, deadline_at_ms], Task).

terminal_event_payload(Task) ->
    maps:with([status, reason], Task).

emit_service_task(undefined, _Type, _Task, _Payload) ->
    ok;
emit_service_task(EventStore, Type, Task, Payload) ->
    StableIds = maps:with(
                  [task_id, request_id, run_id, correlation_id], Task),
    soma_event_store:append(
      EventStore,
      StableIds#{event_type => Type, payload => Payload}).

runtime_event_store() ->
    case whereis(soma_sup) of
        undefined ->
            undefined;
        _SupPid ->
            Children = supervisor:which_children(soma_sup),
            case lists:keyfind(soma_event_store, 1, Children) of
                {soma_event_store, StorePid, _Type, _Modules}
                  when is_pid(StorePid) ->
                    StorePid;
                false ->
                    undefined
            end
    end.

mint_id(Prefix) ->
    PrefixBin = list_to_binary(Prefix),
    Random = binary:encode_hex(crypto:strong_rand_bytes(16)),
    <<PrefixBin/binary, Random/binary>>.
