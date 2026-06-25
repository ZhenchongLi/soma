%% @doc A single actor instance, as a `gen_statem'. This slice gives it the
%% `gen_statem' shape only: it implements the behaviour and exports
%% `start_link/1', `callback_mode/0', and `init/1'. Later slices add the
%% `idle' state, config in the data record, and `actor.started' emission.
-module(soma_actor).

-behaviour(gen_statem).

-export([start_link/1]).
-export([send/2]).
-export([ask/3]).
-export([get_task_status/2]).
-export([get_task_result/2]).
-export([cancel/2]).
-export([callback_mode/0, init/1]).
-export([idle/3]).

-record(data, {actor_id, model_config, tool_policy, event_store, tasks = #{},
               runs = #{}, waiters = #{}, monitors = #{}, llm_calls = #{}}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% @doc Synchronous entry point. Hands the envelope to the actor process and
%% returns `{ok, TaskId}' once the task is accepted, or `{error, Reason}' if the
%% envelope is invalid. The work runs inside the actor via `idle/3', so the
%% actor is never bypassed.
send(ActorRef, Envelope) ->
    gen_statem:call(ActorRef, {send, Envelope}).

%% @doc Synchronous submit-and-wait entry point. Hands the envelope to the actor
%% and blocks the caller inside the `gen_statem:call' until the run completes,
%% then returns `{ok, Result}' with the run's outputs. An invalid envelope is
%% rejected with `{error, Reason}' straight away. If `TimeoutMs' fires before the
%% run completes the call returns `timeout' on the caller side while the actor
%% finishes the task. The work runs inside the actor via `idle/3', so the actor
%% is never bypassed.
ask(ActorRef, Envelope, TimeoutMs) ->
    try
        gen_statem:call(ActorRef, {ask, Envelope}, TimeoutMs)
    catch
        exit:{timeout, _} ->
            timeout
    end.

%% @doc Reads a task's current status from the actor's task table. Returns a map
%% carrying `task_id', `correlation_id', and `status'. The read runs inside the
%% actor via `idle/3', so the actor is never bypassed.
get_task_status(ActorRef, TaskId) ->
    gen_statem:call(ActorRef, {get_task_status, TaskId}).

%% @doc Reads a task's result from the actor's task table. Returns
%% `{ok, Result}' once the task has completed, or `not_ready' while it has not
%% yet completed. The read runs inside the actor via `idle/3', so the actor is
%% never bypassed.
get_task_result(ActorRef, TaskId) ->
    gen_statem:call(ActorRef, {get_task_result, TaskId}).

%% @doc Requests cancellation of a task's in-flight run. Looks the task up and
%% sends the atom `cancel' to the live run pid, which kills the active tool-call
%% worker, records `run.cancelled', and reports back with `{run_cancelled,
%% RunId}'. Returns `ok' for "cancel requested" (not "cancel finished") when
%% there is a live run, `{error, not_found}' for an unknown task, and
%% `{error, not_running}' for a task with no live run. The actor never kills the
%% worker itself -- that crosses a process boundary, which is the design. The
%% call runs inside the actor via `idle/3', so the actor is never bypassed.
cancel(ActorRef, TaskId) ->
    gen_statem:call(ActorRef, {cancel, TaskId}).

callback_mode() ->
    state_functions.

init(Opts) ->
    Data = #data{actor_id = maps:get(actor_id, Opts, undefined),
                 model_config = maps:get(model_config, Opts, undefined),
                 tool_policy = maps:get(tool_policy, Opts, undefined),
                 event_store = maps:get(event_store, Opts, undefined)},
    emit(Data, <<"actor.started">>, #{}),
    {ok, idle, Data}.

idle({call, From}, {send, Envelope}, Data) ->
    case validate_envelope(Envelope) of
        ok ->
            TaskId = resolve_task_id(Envelope),
            CorrelationId = resolve_correlation_id(Envelope, TaskId),
            Task = #{correlation_id => CorrelationId, status => accepted},
            Tasks = maps:put(TaskId, Task, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
            emit(Data1, <<"actor.message.received">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            emit(Data1, <<"actor.task.accepted">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            Data2 = maybe_start_run(Envelope, TaskId, CorrelationId, Data1),
            Data3 = maybe_start_llm_call(Envelope, TaskId, CorrelationId, Data2),
            {keep_state, Data3, [{reply, From, {ok, TaskId}}]};
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end;
idle({call, From}, {ask, Envelope}, Data) ->
    case validate_envelope(Envelope) of
        ok ->
            TaskId = resolve_task_id(Envelope),
            CorrelationId = resolve_correlation_id(Envelope, TaskId),
            Task = #{correlation_id => CorrelationId, status => accepted},
            Tasks = maps:put(TaskId, Task, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
            emit(Data1, <<"actor.message.received">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            emit(Data1, <<"actor.task.accepted">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            Data2 = maybe_start_run(Envelope, TaskId, CorrelationId, Data1),
            case maps:get(steps, Envelope, undefined) of
                Steps when is_list(Steps) ->
                    %% A run was started: defer the reply, parking From against
                    %% the task to answer when the run completes. The caller
                    %% stays blocked inside its gen_statem:call.
                    Waiters = maps:put(TaskId, From, Data2#data.waiters),
                    {keep_state, Data2#data{waiters = Waiters}};
                _ ->
                    %% No-steps envelope: valid, but starts no run, so no
                    %% terminal event will ever fire. Reply immediately with the
                    %% distinct 3-tuple {ok, accepted, TaskId} and park no
                    %% waiter, rather than blocking the caller until TimeoutMs.
                    {keep_state, Data2,
                     [{reply, From, {ok, accepted, TaskId}}]}
            end;
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end;
idle({call, From}, {get_task_status, TaskId}, Data) ->
    Status = case maps:get(TaskId, Data#data.tasks, undefined) of
                 undefined ->
                     #{task_id => TaskId, status => not_found};
                 Task ->
                     #{task_id => TaskId,
                       correlation_id => maps:get(correlation_id, Task),
                       status => maps:get(status, Task)}
             end,
    {keep_state, Data, [{reply, From, Status}]};
idle({call, From}, {get_task_result, TaskId}, Data) ->
    Reply = case maps:get(TaskId, Data#data.tasks, undefined) of
                undefined ->
                    {error, not_found};
                Task ->
                    case maps:get(result, Task, undefined) of
                        undefined -> not_ready;
                        Result -> {ok, Result}
                    end
            end,
    {keep_state, Data, [{reply, From, Reply}]};
idle({call, From}, {cancel, TaskId}, Data) ->
    case maps:get(TaskId, Data#data.tasks, undefined) of
        undefined ->
            {keep_state, Data, [{reply, From, {error, not_found}}]};
        Task ->
            Status = maps:get(status, Task),
            RunPid = maps:get(run_pid, Task, undefined),
            WorkerPid = maps:get(llm_call_pid, Task, undefined),
            case {Status, RunPid, WorkerPid} of
                {running, RunPid1, _} when is_pid(RunPid1) ->
                    RunPid1 ! cancel,
                    {keep_state, Data, [{reply, From, ok}]};
                {running, _, WorkerPid1} when is_pid(WorkerPid1) ->
                    %% Cancel of an in-flight LLM call. Unlike a soma_run, the
                    %% bare worker has no state machine to receive a `cancel'
                    %% message, so the actor does the kill itself
                    %% (exit(WorkerPid, kill)) -- the same brutal teardown the
                    %% timeout path uses. Demonitor-and-flush the worker ref so
                    %% the kill's `'DOWN'' never reaches the backstop, cancel the
                    %% call-timeout timer, record the task `cancelled', and emit
                    %% `llm.cancelled'. The actor stays alive.
                    exit(WorkerPid1, kill),
                    LlmCallId = maps:get(llm_call_id, Task),
                    Data0 = clear_llm_timer(TaskId,
                                            clear_llm_monitor(TaskId, Data)),
                    Task0 = maps:get(TaskId, Data0#data.tasks),
                    CorrelationId = maps:get(correlation_id, Task0),
                    Task1 = Task0#{status => cancelled},
                    Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
                    Data1 = Data0#data{tasks = Tasks},
                    emit(Data1, <<"llm.cancelled">>,
                         #{task_id => TaskId, correlation_id => CorrelationId,
                           llm_call_id => LlmCallId}),
                    {keep_state, Data1, [{reply, From, ok}]};
                _ ->
                    {keep_state, Data, [{reply, From, {error, not_running}}]}
            end
    end;
idle(info, {run_completed, RunId, Outputs}, Data) ->
    case maps:get(RunId, Data#data.runs, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Data0 = clear_monitor(TaskId, Data),
            Task = maps:get(TaskId, Data0#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => completed, result => Outputs},
            Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
            Data1 = Data0#data{tasks = Tasks},
            emit(Data1, <<"actor.result.created">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            emit(Data1, <<"actor.task.completed">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            reply_waiter(TaskId, {ok, Outputs}, Data1)
    end;
idle(info, {run_failed, RunId, Reason}, Data) ->
    case maps:get(RunId, Data#data.runs, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Data0 = clear_monitor(TaskId, Data),
            Task = maps:get(TaskId, Data0#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => failed, reason => Reason},
            Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
            Data1 = Data0#data{tasks = Tasks},
            emit(Data1, <<"actor.task.failed">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   reason => Reason}),
            reply_waiter(TaskId, {error, Reason}, Data1)
    end;
idle(info, {run_timeout, RunId}, Data) ->
    case maps:get(RunId, Data#data.runs, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Data0 = clear_monitor(TaskId, Data),
            Task = maps:get(TaskId, Data0#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => failed, reason => timeout},
            Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
            Data1 = Data0#data{tasks = Tasks},
            emit(Data1, <<"actor.task.failed">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   reason => timeout}),
            reply_waiter(TaskId, {error, timeout}, Data1)
    end;
idle(info, {run_cancelled, RunId}, Data) ->
    case maps:get(RunId, Data#data.runs, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Data0 = clear_monitor(TaskId, Data),
            Task = maps:get(TaskId, Data0#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => cancelled},
            Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
            Data1 = Data0#data{tasks = Tasks},
            emit(Data1, <<"actor.task.cancelled">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            reply_waiter(TaskId, {error, cancelled}, Data1)
    end;
%% The LLM worker reported a successful mock call. Map the llm_call_id back to its
%% task, demonitor-and-flush the worker ref so its later normal `'DOWN'' never
%% reaches the backstop clause, record the task `completed' with the call output
%% as its result (so get_task_result returns {ok, Output}), emit `llm.succeeded',
%% and release any parked ask waiter.
idle(info, {llm_result, LlmCallId, _WorkerPid, {ok, Output}}, Data) ->
    case maps:get(LlmCallId, Data#data.llm_calls, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Data0 = clear_llm_timer(TaskId, clear_llm_monitor(TaskId, Data)),
            Task = maps:get(TaskId, Data0#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => completed, result => Output},
            Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
            Data1 = Data0#data{tasks = Tasks},
            emit(Data1, <<"llm.succeeded">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   llm_call_id => LlmCallId}),
            reply_waiter(TaskId, {ok, Output}, Data1)
    end;
%% The call-timeout timer the actor armed fired before the worker reported a
%% result -- a `slow' mock that ignored the timer. The actor enforces the bound:
%% it kills the worker (exit(WorkerPid, kill), since the bare worker has no state
%% machine to drive its own teardown), demonitor-and-flushes the worker ref so the
%% kill's `'DOWN'' never reaches the backstop, records the task `timeout', emits
%% `llm.timeout', and releases any parked ask waiter. The actor stays alive.
idle(info, {timeout, _TimerRef, {llm_timeout, LlmCallId}}, Data) ->
    case maps:get(LlmCallId, Data#data.llm_calls, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Task = maps:get(TaskId, Data#data.tasks),
            case maps:get(llm_call_pid, Task, undefined) of
                WorkerPid when is_pid(WorkerPid) ->
                    exit(WorkerPid, kill);
                _ ->
                    ok
            end,
            Data0 = clear_llm_monitor(TaskId, Data),
            Task0 = maps:get(TaskId, Data0#data.tasks),
            CorrelationId = maps:get(correlation_id, Task0),
            Task1 = Task0#{status => timeout},
            Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
            Data1 = Data0#data{tasks = Tasks},
            emit(Data1, <<"llm.timeout">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   llm_call_id => LlmCallId}),
            reply_waiter(TaskId, {error, timeout}, Data1)
    end;
%% The run pid died without sending one of the four terminal messages -- a crash
%% inside soma_run itself, not a tool crash the run catches and reports. The
%% monitor delivers `'DOWN'' with a non-`normal' reason. Record the task as a
%% terminal `failed' (data, not a stuck `running') and release any parked ask
%% waiter. A `normal' exit means a terminal message already arrived and
%% demonitor-flushed this ref, so a `normal' `'DOWN'' is never seen here.
idle(info, {'DOWN', MRef, process, _RunPid, Reason}, Data)
  when Reason =/= normal ->
    case maps:get(MRef, Data#data.monitors, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Monitors = maps:remove(MRef, Data#data.monitors),
            %% If this was an llm worker, cancel its armed call-timeout timer and
            %% drop its `llm_calls' entry. Otherwise a still-live timer fires
            %% later, finds the task in `llm_calls', and flips `failed' ->
            %% `timeout' with a spurious `llm.timeout' against the dead worker.
            %% A run crash carries no llm timer/entry, so this is a no-op there.
            Data0 = clear_llm_call(TaskId,
                                   Data#data{monitors = Monitors}),
            Task = maps:get(TaskId, Data0#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => failed, reason => Reason},
            Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
            Data1 = Data0#data{tasks = Tasks},
            %% When the dead process was an LLM worker the task carries an
            %% `llm_call_id' (`clear_llm_call/2' leaves it on the task map). Emit
            %% `llm.failed' first so the trail reads worker-level cause before the
            %% task-level outcome, mirroring the success path. A `soma_run' crash
            %% has no `llm_call_id', so nothing extra is emitted there.
            case maps:get(llm_call_id, Task1, undefined) of
                undefined ->
                    ok;
                LlmCallId ->
                    emit(Data1, <<"llm.failed">>,
                         #{task_id => TaskId, correlation_id => CorrelationId,
                           llm_call_id => LlmCallId})
            end,
            emit(Data1, <<"actor.task.failed">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   reason => Reason}),
            reply_waiter(TaskId, {error, Reason}, Data1)
    end;
idle(_EventType, _Event, Data) ->
    {keep_state, Data}.

validate_envelope(Envelope) when is_map(Envelope) ->
    case maps:is_key(type, Envelope) andalso maps:is_key(payload, Envelope) of
        true ->
            %% Decision 1, mutual exclusion: `steps' (a run) and `llm' (a call)
            %% are two distinct dispatch paths. An envelope carrying both is
            %% malformed and rejected up front -- before any child starts -- so
            %% the dispatch never starts two children for one task.
            case has_steps(Envelope) andalso has_llm(Envelope) of
                true -> {error, steps_and_llm_mutually_exclusive};
                false -> validate_steps(maps:get(steps, Envelope, undefined))
            end;
        false -> {error, missing_required_field}
    end;
validate_envelope(_Envelope) ->
    {error, not_a_map}.

has_steps(Envelope) ->
    is_list(maps:get(steps, Envelope, undefined)).

has_llm(Envelope) ->
    is_map(maps:get(llm, Envelope, undefined)).

%% A no-steps envelope is valid by design. When the envelope carries a steps
%% list, each step must be a map with an `id' and a `tool' so a known-bad step
%% list never reaches soma_run (where a missing `id' would crash the run and
%% leave the task stuck at `running').
validate_steps(undefined) ->
    ok;
validate_steps(Steps) when is_list(Steps) ->
    case lists:all(fun valid_step/1, Steps) of
        true -> ok;
        false -> {error, malformed_steps}
    end;
validate_steps(_Steps) ->
    {error, malformed_steps}.

valid_step(Step) when is_map(Step) ->
    maps:is_key(id, Step) andalso maps:is_key(tool, Step);
valid_step(_Step) ->
    false.

resolve_task_id(Envelope) ->
    case maps:get(task_id, Envelope, undefined) of
        undefined -> mint_task_id();
        TaskId -> TaskId
    end.

resolve_correlation_id(Envelope, TaskId) ->
    maps:get(correlation_id, Envelope, TaskId).

%% When the envelope carries a steps list, start a soma_run that the actor owns
%% (session_pid => self()) and track run_id => task_id so the terminal message
%% maps back to the task. With no steps the slice-4 behavior is unchanged.
maybe_start_run(Envelope, TaskId, CorrelationId, Data) ->
    case maps:get(steps, Envelope, undefined) of
        Steps when is_list(Steps) ->
            RunId = mint_run_id(),
            RunOpts = #{run_id => RunId,
                        session_id => Data#data.actor_id,
                        session_pid => self(),
                        event_store => Data#data.event_store,
                        steps => Steps,
                        correlation_id => CorrelationId},
            {ok, RunPid} = soma_run_sup:start_run(RunOpts),
            %% Monitor the run pid, mirroring soma_run -> soma_tool_call. A run
            %% that dies without sending one of the four terminal messages
            %% (a crash inside soma_run itself, not a tool crash it catches)
            %% arrives here as a `'DOWN'' and is recorded as a terminal `failed'
            %% task -- data, not a stuck `running'. The normal terminal messages
            %% demonitor-and-flush so a still-alive completed run leaves no
            %% dangling monitor.
            MRef = erlang:monitor(process, RunPid),
            Runs = maps:put(RunId, TaskId, Data#data.runs),
            Monitors = maps:put(MRef, TaskId, Data#data.monitors),
            Task = maps:get(TaskId, Data#data.tasks),
            Task1 = Task#{status => running, run_id => RunId,
                          run_pid => RunPid, run_mref => MRef},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data#data{runs = Runs, tasks = Tasks, monitors = Monitors};
        _ ->
            Data
    end.

%% When the envelope carries an `llm' directive map, start a soma_llm_call worker
%% the actor owns directly (owner => self()), mirroring soma_run -> soma_tool_call:
%% the worker runs in its own process so its pid is distinct from the actor pid.
%% The actor mints an `llm_call_id', monitors the worker, tracks llm_call_id =>
%% task_id, records the task running, and emits `llm.started' carrying the worker
%% pid. With no `llm' field this is a no-op.
maybe_start_llm_call(Envelope, TaskId, CorrelationId, Data) ->
    case maps:get(llm, Envelope, undefined) of
        Llm when is_map(Llm) ->
            LlmCallId = mint_llm_call_id(),
            {ok, WorkerPid} = soma_llm_call:start(#{owner => self(),
                                                    llm_call_id => LlmCallId,
                                                    llm => Llm}),
            MRef = erlang:monitor(process, WorkerPid),
            %% Arm a call-timeout timer the actor owns: when it fires before the
            %% worker reports a result, the actor kills the worker and records
            %% `timeout'. The owner enforces the bound, mirroring soma_run's
            %% per-step state_timeout -- a `slow' mock that ignores the timer is
            %% exactly the case this proves. The timer carries the llm_call_id so
            %% the firing maps back to its task. With no timeout_ms, no timer.
            TimerRef = arm_llm_timeout(maps:get(timeout_ms, Llm, undefined),
                                       LlmCallId),
            LlmCalls = maps:put(LlmCallId, TaskId, Data#data.llm_calls),
            Monitors = maps:put(MRef, TaskId, Data#data.monitors),
            Task = maps:get(TaskId, Data#data.tasks),
            Task1 = Task#{status => running, llm_call_id => LlmCallId,
                          llm_call_pid => WorkerPid, llm_call_mref => MRef,
                          llm_timer_ref => TimerRef},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data1 = Data#data{llm_calls = LlmCalls, tasks = Tasks,
                              monitors = Monitors},
            emit(Data1, <<"llm.started">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   llm_call_id => LlmCallId, llm_call_pid => WorkerPid}),
            Data1;
        _ ->
            Data
    end.

%% On a normal terminal message (run_completed | run_failed | run_timeout |
%% run_cancelled) the run pid is reporting its own outcome and may still be
%% alive momentarily. Demonitor-and-flush its ref so a later clean (or even
%% non-normal) `'DOWN'' for this run never reaches the backstop clause, and drop
%% the ref from the monitors map so no dangling entry survives.
clear_monitor(TaskId, Data) ->
    Task = maps:get(TaskId, Data#data.tasks),
    case maps:get(run_mref, Task, undefined) of
        undefined ->
            Data;
        MRef ->
            erlang:demonitor(MRef, [flush]),
            Monitors = maps:remove(MRef, Data#data.monitors),
            Data#data{monitors = Monitors}
    end.

%% The LLM-worker counterpart of clear_monitor: on the worker's terminal result
%% demonitor-and-flush its ref so its later normal `'DOWN'' never reaches the
%% backstop clause, and drop the ref from the monitors map.
clear_llm_monitor(TaskId, Data) ->
    Task = maps:get(TaskId, Data#data.tasks),
    case maps:get(llm_call_mref, Task, undefined) of
        undefined ->
            Data;
        MRef ->
            erlang:demonitor(MRef, [flush]),
            Monitors = maps:remove(MRef, Data#data.monitors),
            Data#data{monitors = Monitors}
    end.

%% Arm the actor-owned call-timeout timer, keyed by the llm_call_id so its firing
%% message maps back to the task. With no timeout_ms there is no bound to enforce,
%% so no timer is armed and the ref is `undefined'.
arm_llm_timeout(undefined, _LlmCallId) ->
    undefined;
arm_llm_timeout(TimeoutMs, LlmCallId) when is_integer(TimeoutMs) ->
    erlang:start_timer(TimeoutMs, self(), {llm_timeout, LlmCallId}).

%% On the worker's terminal result, cancel the call-timeout timer (the bound was
%% met in time) so a stale timer never fires against a finished task. A flushed
%% cancel drops any already-queued firing message. No timer to cancel is a no-op.
clear_llm_timer(TaskId, Data) ->
    Task = maps:get(TaskId, Data#data.tasks),
    case maps:get(llm_timer_ref, Task, undefined) of
        undefined ->
            Data;
        TimerRef ->
            erlang:cancel_timer(TimerRef, [{async, false}, {info, false}]),
            Data
    end.

%% When an llm worker's crash reaches the actor through the monitor `'DOWN'',
%% tear down its call bookkeeping the same way the result and timeout paths do:
%% cancel the armed call-timeout timer and drop the `llm_calls' entry keyed by
%% the task's `llm_call_id'. A task with no `llm_call_id' (a soma_run crash) has
%% nothing to clear, so this is a no-op there.
clear_llm_call(TaskId, Data) ->
    Data0 = clear_llm_timer(TaskId, Data),
    Task = maps:get(TaskId, Data0#data.tasks),
    case maps:get(llm_call_id, Task, undefined) of
        undefined ->
            Data0;
        LlmCallId ->
            LlmCalls = maps:remove(LlmCallId, Data0#data.llm_calls),
            Data0#data{llm_calls = LlmCalls}
    end.

%% If an ask/3 caller is parked on this task, reply with the given term to it and
%% drop the waiter. The success path passes {ok, Outputs}, the failure path
%% {error, Reason}. A send-started task has no waiter, so this is a no-op for send.
reply_waiter(TaskId, Reply, Data) ->
    case maps:get(TaskId, Data#data.waiters, undefined) of
        undefined ->
            {keep_state, Data};
        From ->
            Waiters = maps:remove(TaskId, Data#data.waiters),
            {keep_state, Data#data{waiters = Waiters},
             [{reply, From, Reply}]}
    end.

mint_run_id() ->
    list_to_binary(
      "run-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

mint_task_id() ->
    list_to_binary(
      "task-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

mint_llm_call_id() ->
    list_to_binary(
      "llm-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

emit(#data{event_store = undefined}, _Type, _Extra) ->
    ok;
emit(Data, Type, Extra) ->
    Base = #{actor_id => Data#data.actor_id,
             event_type => Type},
    Event = maps:merge(Base, Extra),
    soma_event_store:append(Data#data.event_store, Event),
    ok.
