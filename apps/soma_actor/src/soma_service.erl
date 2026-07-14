%% @doc Supervised owner for already-decided service invocations. The service
%% normalizes an invoke envelope, admits its canonical steps through the
%% configured policy, and owns the resulting `soma_run' monitor and task view.
-module(soma_service).

-behaviour(gen_server).

-export([start_link/0]).
-export([invoke/1, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {event_store,
                policy = #{allowed_tools => []},
                tasks = #{},
                requests = #{},
                runs = #{},
                monitors = #{}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

invoke(Envelope) ->
    gen_server:call(?MODULE, {invoke, Envelope}).

status(TaskId) ->
    gen_server:call(?MODULE, {status, TaskId}).

init([]) ->
    Policy = application:get_env(
               soma_actor, service_policy,
               #{allowed_tools => []}),
    State = #state{event_store = runtime_event_store(), policy = Policy},
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
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({run_completed, RunId, Outputs}, State) ->
    {noreply,
     finish_run(RunId, {completed, Outputs}, State)};
handle_info({run_failed, RunId, Reason}, State) ->
    {noreply,
     finish_run(RunId, #{status => failed, reason => Reason}, State)};
handle_info({run_timeout, RunId}, State) ->
    {noreply,
     finish_run(RunId, #{status => failed, reason => timeout}, State)};
handle_info({run_cancelled, RunId}, State) ->
    {noreply, finish_run(RunId, #{status => cancelled}, State)};
handle_info({timeout, TRef, {task_deadline, TaskId, RunId}}, State) ->
    {noreply, expire_deadline(TRef, TaskId, RunId, State)};
handle_info({'DOWN', MRef, process, RunPid, Reason},
            State = #state{monitors = Monitors}) ->
    case maps:get(MRef, Monitors, undefined) of
        #{run_id := RunId, run_pid := RunPid} ->
            {noreply,
             finish_run(RunId,
                        #{status => failed,
                          reason => {run_crashed, Reason}},
                        State)};
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

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
    Handle = #{task_id => TaskId,
               request_id => RequestId,
               status => accepted},
    Task0 = #{task_id => TaskId,
              request_id => RequestId,
              envelope_hash => EnvelopeHash,
              status => accepted,
              run_id => RunId},
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
              Envelope, Steps, Task, Handle, AdmittedState);
        {reject, Reason} ->
            reject_invocation(Reason, Task, AdmittedState)
    end.

start_allowed_invocation(Envelope, Steps, Task, Handle,
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
                 session_pid => self(),
                 event_store => EventStore,
                 steps => Steps},
    RunOpts = maybe_add_correlation(Envelope, RunOpts0),
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
        {error, Reason} ->
            {reply, {error, {run_start_failed, Reason}}, State}
    end.

reject_invocation(Reason, Task,
                  State = #state{event_store = EventStore,
                                 tasks = Tasks}) ->
    Rejection = {policy_rejected, Reason},
    Terminal = Task#{status => rejected, reason => Rejection},
    ok = emit_service_task(EventStore, <<"service.task.terminal">>,
                           Terminal, terminal_event_payload(Terminal)),
    TaskId = maps:get(task_id, Task),
    NewState = State#state{tasks = maps:put(TaskId, Terminal, Tasks)},
    {reply, {ok, public_task(Terminal)}, NewState}.

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

maybe_add_correlation(Envelope, RunOpts) ->
    case maps:find(correlation_id, Envelope) of
        {ok, CorrelationId} ->
            RunOpts#{correlation_id => CorrelationId};
        error ->
            RunOpts
    end.

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
                         deadline_expired],
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

cancel_deadline(#{deadline_tref := TRef}) ->
    _ = erlang:cancel_timer(TRef, [{async, false}, {info, false}]),
    ok;
cancel_deadline(_Task) ->
    ok.

terminate_run_child(RunPid) ->
    _ = supervisor:terminate_child(soma_run_sup, RunPid),
    ok.

public_task(Task) ->
    maps:with([task_id, request_id, status, result, reason], Task).

%% Rebuild the request-id index from the bounded service lifecycle trail. The
%% event store is the source of truth; task and request maps are only the live
%% cache owned by this service process.
rebuild_dedupe_index(State = #state{event_store = undefined}) ->
    State;
rebuild_dedupe_index(State = #state{event_store = EventStore}) ->
    Events = soma_event_store:all(EventStore),
    Accepted =
        [Event || Event <- Events,
                  maps:get(event_type, Event, undefined) =:=
                      <<"service.task.accepted">>],
    lists:foldl(
      fun(Event, Acc) -> recover_accepted_task(Event, Events, Acc) end,
      State,
      Accepted).

recover_accepted_task(Event, Events, State) ->
    case accepted_task(Event) of
        {ok, Task, Request} ->
            TaskId = maps:get(task_id, Task),
            case last_terminal_event(TaskId, Events) of
                {ok, TerminalEvent} ->
                    recover_recorded_terminal(
                      Task, Request, TerminalEvent, State);
                error ->
                    recover_unfinished_task(Task, Request, State)
            end;
        error ->
            State
    end.

accepted_task(#{task_id := TaskId,
                request_id := RequestId,
                run_id := RunId,
                payload := #{envelope_hash := EnvelopeHash} = Payload}) ->
    Handle = #{task_id => TaskId,
               request_id => RequestId,
               status => accepted},
    Task0 = #{task_id => TaskId,
              request_id => RequestId,
              run_id => RunId,
              envelope_hash => EnvelopeHash,
              status => running},
    Task = maybe_restore_max_output_bytes(Payload, Task0),
    Request = #{envelope_hash => EnvelopeHash,
                task_id => TaskId,
                accepted_handle => Handle},
    {ok, Task, Request};
accepted_task(_Event) ->
    error.

last_terminal_event(TaskId, Events) ->
    lists:foldl(
      fun(#{event_type := <<"service.task.terminal">>,
            task_id := EventTaskId} = Event, _Acc)
            when EventTaskId =:= TaskId ->
              {ok, Event};
         (_Event, Acc) ->
              Acc
      end,
      error,
      Events).

recover_recorded_terminal(Task, Request,
                          #{payload := #{status := succeeded}}, State) ->
    case reconstructed_terminal(Task, State) of
        {ok, Recovered} -> put_terminal_task(Recovered, Request, State);
        error -> put_terminal_task(
                   Task#{status => failed,
                         reason => service_result_reconstruction_failed},
                   Request, State)
    end;
recover_recorded_terminal(Task, Request,
                          #{payload := Payload}, State) ->
    Status = maps:get(status, Payload, failed),
    Terminal0 = Task#{status => Status},
    Terminal = case maps:find(reason, Payload) of
                   {ok, Reason} -> Terminal0#{reason => Reason};
                   error -> Terminal0
               end,
    put_terminal_task(Terminal, Request, State).

recover_unfinished_task(Task, Request, State) ->
    RunId = maps:get(run_id, Task),
    case soma_run_sup:find_run(RunId) of
        {ok, RunPid} ->
            case soma_run:adopt_owner(RunPid, self()) of
                ok ->
                    monitor_recovered_run(Task, Request, RunPid, State);
                {error, {terminal, _Status}} ->
                    terminate_run_child(RunPid),
                    recover_from_run_trail(Task, Request, State)
            end;
        {error, not_found} ->
            recover_from_run_trail(Task, Request, State)
    end.

monitor_recovered_run(Task, Request, RunPid,
                      State = #state{tasks = Tasks,
                                     requests = Requests,
                                     runs = Runs,
                                     monitors = Monitors}) ->
    MRef = erlang:monitor(process, RunPid),
    RunId = maps:get(run_id, Task),
    TaskId = maps:get(task_id, Task),
    Running = Task#{status => running,
                    run_pid => RunPid,
                    run_mref => MRef},
    State#state{
      tasks = maps:put(TaskId, Running, Tasks),
      requests = maps:put(maps:get(request_id, Task), Request, Requests),
      runs = maps:put(RunId, TaskId, Runs),
      monitors = maps:put(MRef,
                          #{run_id => RunId, run_pid => RunPid},
                          Monitors)}.

recover_from_run_trail(Task, Request,
                       State = #state{event_store = EventStore}) ->
    case reconstructed_terminal(Task, State) of
        {ok, Terminal} ->
            ok = emit_service_task(EventStore,
                                   <<"service.task.terminal">>,
                                   Terminal,
                                   terminal_event_payload(Terminal)),
            put_terminal_task(Terminal, Request, State);
        error ->
            %% Keep the immutable dedupe identity even when the trail is still
            %% nonterminal. Later recovery criteria decide whether such a run is
            %% resumable or in doubt; an identical request must never start a
            %% replacement merely because the in-memory owner restarted.
            put_terminal_task(Task#{status => running}, Request, State)
    end.

reconstructed_terminal(Task, #state{event_store = EventStore}) ->
    RunId = maps:get(run_id, Task),
    case soma_run_resume:reconstruct(EventStore, RunId) of
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

put_terminal_task(Task, Request,
                  State = #state{tasks = Tasks, requests = Requests}) ->
    TaskId = maps:get(task_id, Task),
    RequestId = maps:get(request_id, Task),
    State#state{tasks = maps:put(TaskId, Task, Tasks),
                requests = maps:put(RequestId, Request, Requests)}.

maybe_restore_max_output_bytes(#{max_output_bytes := MaxOutputBytes}, Task) ->
    Task#{max_output_bytes => MaxOutputBytes};
maybe_restore_max_output_bytes(_Payload, Task) ->
    Task.

accepted_event_payload(Task) ->
    maps:with([envelope_hash, max_output_bytes, deadline_at_ms], Task).

terminal_event_payload(Task) ->
    maps:with([status, reason], Task).

emit_service_task(undefined, _Type, _Task, _Payload) ->
    ok;
emit_service_task(EventStore, Type, Task, Payload) ->
    StableIds = maps:with([task_id, request_id, run_id], Task),
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
    list_to_binary(
      Prefix ++ integer_to_list(
                  erlang:unique_integer([positive, monotonic]))).
