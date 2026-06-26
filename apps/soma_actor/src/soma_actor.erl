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
-export([build_call_opts/2]).
-export([callback_mode/0, init/1]).
-export([idle/3]).

-record(data, {actor_id, model_config, tool_policy, event_store, tasks = #{},
               runs = #{}, waiters = #{}, monitors = #{}, llm_calls = #{},
               budget = #{}, llm_call_counts = #{}, repair = auto,
               max_repairs = 1}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% @doc Synchronous entry point. Hands the envelope to the actor process and
%% returns `{ok, TaskId}' once the task is accepted, or `{error, Reason}' if the
%% envelope is invalid. The work runs inside the actor via `idle/3', so the
%% actor is never bypassed.
send(ActorRef, Envelope) when is_map(Envelope) ->
    gen_statem:call(ActorRef, {send, Envelope});
send(ActorRef, Source) when is_binary(Source); is_list(Source) ->
    %% A Lisp `(msg ...)' string (binary or iolist) is parsed at the wrapper,
    %% before the actor is touched, into the exact map envelope the map path
    %% takes. The actor's message contract stays map-only -- it never learns
    %% Lisp exists. A parse error is returned to the caller without calling the
    %% actor at all.
    case soma_lfe:compile(Source, #{}) of
        {ok, Envelope} ->
            send(ActorRef, Envelope);
        {error, Diagnostics} ->
            {error, Diagnostics}
    end.

%% @doc Synchronous submit-and-wait entry point. Hands the envelope to the actor
%% and blocks the caller inside the `gen_statem:call' until the run completes,
%% then returns `{ok, Result}' with the run's outputs. An invalid envelope is
%% rejected with `{error, Reason}' straight away. If `TimeoutMs' fires before the
%% run completes the call returns `timeout' on the caller side while the actor
%% finishes the task. The work runs inside the actor via `idle/3', so the actor
%% is never bypassed.
ask(ActorRef, Envelope, TimeoutMs) when is_map(Envelope) ->
    try
        gen_statem:call(ActorRef, {ask, Envelope}, TimeoutMs)
    catch
        exit:{timeout, _} ->
            timeout
    end;
ask(ActorRef, Source, TimeoutMs) when is_binary(Source); is_list(Source) ->
    %% A Lisp `(msg ...)' string (binary or iolist) is parsed at the wrapper,
    %% before the actor is touched, into the exact map envelope the map path
    %% takes -- mirroring send/2. The actor's message contract stays map-only.
    %% A parse error is returned to the caller without calling the actor at all.
    case soma_lfe:compile(Source, #{}) of
        {ok, Envelope} ->
            ask(ActorRef, Envelope, TimeoutMs);
        {error, Diagnostics} ->
            {error, Diagnostics}
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
                 event_store = maps:get(event_store, Opts, undefined),
                 budget = maps:get(budget, Opts, #{}),
                 repair = maps:get(repair, Opts, auto),
                 max_repairs = maps:get(max_repairs, Opts, 1)},
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
                    case has_llm(Envelope) of
                        true ->
                            %% An `llm' envelope: park From against the task,
                            %% then start the LLM call. The decision loop ends in
                            %% a terminal task event (or a budget failure through
                            %% the shared failure helper), each of which releases
                            %% the parked waiter -- so a budget-failed `llm' task
                            %% answers the caller with `{error, Reason}' rather
                            %% than blocking until TimeoutMs.
                            Waiters = maps:put(TaskId, From,
                                               Data2#data.waiters),
                            Data3 = maybe_start_llm_call(
                                      Envelope, TaskId, CorrelationId,
                                      Data2#data{waiters = Waiters}),
                            {keep_state, Data3};
                        false ->
                            %% No-steps, no-llm envelope: valid, but starts no
                            %% child, so no terminal event will ever fire. Reply
                            %% immediately with the distinct 3-tuple
                            %% {ok, accepted, TaskId} and park no waiter, rather
                            %% than blocking the caller until TimeoutMs.
                            {keep_state, Data2,
                             [{reply, From, {ok, accepted, TaskId}}]}
                    end
            end;
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end;
idle({call, From}, {get_task_status, TaskId}, Data) ->
    Status = case maps:get(TaskId, Data#data.tasks, undefined) of
                 undefined ->
                     #{task_id => TaskId, status => not_found};
                 Task ->
                     Base = #{task_id => TaskId,
                              correlation_id => maps:get(correlation_id, Task),
                              status => maps:get(status, Task)},
                     case maps:get(reason, Task, undefined) of
                         undefined -> Base;
                         Reason -> Base#{reason => Reason}
                     end
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
            emit(Data0, <<"llm.succeeded">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   llm_call_id => LlmCallId}),
            %% A proposal-shaped output (a map carrying a `kind' tag) is validated
            %% into a tagged proposal: on success the normalized proposal (not the
            %% raw output) becomes the task result so get_task_result/2 returns it.
            %% Output that is not a proposal candidate is stored verbatim, keeping
            %% the v0.5.1 opaque-output contract.
            case proposal_result(Output, maps:get(llm_directive, Task, undefined)) of
                {proposal, Proposal} ->
                    Tasks0 = maps:put(TaskId, Task#{result => Proposal},
                                      Data0#data.tasks),
                    Data0a = Data0#data{tasks = Tasks0},
                    %% A valid proposal was normalized and recorded. Emit
                    %% `proposal.created' carrying the task's correlation_id (and
                    %% the proposal kind). Distinct from `llm.succeeded': the
                    %% latter marks "the call returned a result" and fires on every
                    %% success, this marks "a valid proposal was recorded" and
                    %% fires only on successful normalization (design decision 2).
                    %% Opaque passthrough output is not a normalized proposal, so
                    %% it takes the `opaque' branch and emits nothing here.
                    emit(Data0a, <<"proposal.created">>,
                         #{task_id => TaskId, correlation_id => CorrelationId,
                           llm_call_id => LlmCallId,
                           kind => maps:get(kind, Proposal, undefined)}),
                    %% When this valid proposal is the output of a repair call (the
                    %% task's `repair_count' was bumped above zero when the repair
                    %% call started), a previously malformed proposal has now
                    %% re-parsed. Emit `proposal.repaired' carrying the task's
                    %% `task_id' and `correlation_id' (L.5 criterion 2), distinct
                    %% from `proposal.created'. A first-call success has
                    %% `repair_count' 0 and emits nothing here.
                    case maps:get(repair_count, Task, 0) > 0 of
                        true ->
                            emit(Data0a, <<"proposal.repaired">>,
                                 #{task_id => TaskId,
                                   correlation_id => CorrelationId,
                                   llm_call_id => LlmCallId,
                                   kind => maps:get(kind, Proposal, undefined)});
                        false ->
                            ok
                    end,
                    %% The proposal is data; now the verdict is data too. Run the
                    %% policy gate (a tool-name allowlist) and record the verdict.
                    %% On `allow', emit `proposal.approved' (carrying the task's
                    %% correlation_id and llm_call_id like `proposal.created') and
                    %% set the task status `approved' -- honest that it passed
                    %% policy but has not run (executing is v0.5.4). No run is
                    %% started either way.
                    case soma_policy:check(Proposal, Data0a#data.tool_policy) of
                        allow ->
                            Task1 = (maps:get(TaskId, Data0a#data.tasks))#{
                                      status => approved},
                            Tasks = maps:put(TaskId, Task1, Data0a#data.tasks),
                            Data1 = Data0a#data{tasks = Tasks},
                            emit(Data1, <<"proposal.approved">>,
                                 #{task_id => TaskId, correlation_id => CorrelationId,
                                   llm_call_id => LlmCallId,
                                   kind => maps:get(kind, Proposal, undefined)}),
                            case maps:get(kind, Proposal, undefined) of
                                run_steps ->
                                    %% Approved steps execute: start a run via the
                                    %% shared owned-and-monitored path (the same the
                                    %% direct `steps' envelope uses), leaving the
                                    %% task `running'. The existing run-terminal
                                    %% clauses store the step outputs and complete
                                    %% the task -- and reply any parked waiter from
                                    %% the run's completion, not from this gate.
                                    Steps = maps:get(steps, Proposal),
                                    case steps_budget_available(Steps, Data1) of
                                        false ->
                                            %% Spend point two: the proposal carries
                                            %% more steps than the budget's
                                            %% `max_steps' cap allows. Start no run:
                                            %% fail the task as data through the
                                            %% shared failure path, so no
                                            %% `proposal.executed' / `run.started'
                                            %% fires. The actor stays alive.
                                            Data2 = fail_task(TaskId,
                                                              {budget_exceeded,
                                                               max_steps},
                                                              Data1),
                                            {keep_state, Data2};
                                        true ->
                                            execute_run_steps(Steps, TaskId,
                                                              CorrelationId,
                                                              LlmCallId, Proposal,
                                                              Data1)
                                    end;
                                actor_message ->
                                    %% An approved `actor_message' delivers an
                                    %% envelope to the actor its `to' names. The
                                    %% sender's correlation_id rides into the
                                    %% delivered envelope, so the receiver's task
                                    %% lands under the same id and
                                    %% by_correlation/2 returns both chains. The
                                    %% sender's work is done on delivery.
                                    execute_actor_message(TaskId, CorrelationId,
                                                          LlmCallId, Proposal,
                                                          Data1);
                                _ ->
                                    %% A toolless approved proposal (`reply' /
                                    %% `reject' / `ask') has nothing to run, so it
                                    %% reaches `completed' here with the normalized
                                    %% proposal as the task result (already stored
                                    %% above) -- not resting at `approved'. The
                                    %% `approved' status is a transient step toward
                                    %% `running' only for `run_steps'. No run is
                                    %% started; release any parked waiter with the
                                    %% proposal.
                                    Task2 = (maps:get(TaskId, Data1#data.tasks))#{
                                              status => completed},
                                    Tasks2 = maps:put(TaskId, Task2,
                                                      Data1#data.tasks),
                                    Data2 = Data1#data{tasks = Tasks2},
                                    reply_waiter(TaskId, {ok, Proposal}, Data2)
                            end;
                        {reject, Reason} ->
                            %% The proposal failed policy. Emit
                            %% `proposal.rejected' carrying the reject reason and
                            %% the task's correlation_id (and llm_call_id like
                            %% `proposal.created'), set the task status terminal
                            %% `rejected', and release any parked waiter with the
                            %% rejection. No run is started.
                            Task1 = (maps:get(TaskId, Data0a#data.tasks))#{
                                      status => rejected, reason => Reason},
                            Tasks = maps:put(TaskId, Task1, Data0a#data.tasks),
                            Data1 = Data0a#data{tasks = Tasks},
                            emit(Data1, <<"proposal.rejected">>,
                                 #{task_id => TaskId, correlation_id => CorrelationId,
                                   llm_call_id => LlmCallId, reason => Reason}),
                            reply_waiter(TaskId, {error, {rejected, Reason}}, Data1)
                    end;
                {opaque, Result} ->
                    Task1 = Task#{status => completed, result => Result},
                    Tasks = maps:put(TaskId, Task1, Data0#data.tasks),
                    Data1 = Data0#data{tasks = Tasks},
                    reply_waiter(TaskId, {ok, Result}, Data1);
                {invalid_proposal, Diagnostics} ->
                    %% A malformed proposal is the entry of the bounded repair
                    %% loop (L.5). With repair on (the default), a repair budget
                    %% left, and an llm-call budget left, the actor hands the
                    %% malformed source back to the LLM for one more attempt; the
                    %% repaired output re-enters the full pipeline through an
                    %% ordinary owned llm call. Otherwise the task fails with the
                    %% diagnostics as data, exactly as before.
                    maybe_repair(TaskId, CorrelationId, Diagnostics, Task, Data0)
            end
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

%% The bounded repair loop entry. A malformed proposal is handed back to the LLM
%% for one more attempt when repair is on (`auto', the default), the per-task
%% repair count is below `max_repairs', a `repair_output' is staged on the task,
%% and the llm-call budget has room. The repair call is an ordinary owned
%% `soma_llm_call' built from the staged `repair_output' (a fresh `proposal'
%% directive `llm' map), so its result re-enters the same `proposal_result/2'
%% chain -- no side-path parse-and-inject. When repair is off, exhausted, or the
%% budget is gone, the task fails with the parse diagnostics as data, exactly as
%% before; the actor stays alive either way.
maybe_repair(TaskId, CorrelationId, Diagnostics, Task, Data) ->
    RepairCount = maps:get(repair_count, Task, 0),
    RepairOutput = maps:get(repair_output, Task, undefined),
    WantsRepair = Data#data.repair =/= strict
        andalso RepairCount < Data#data.max_repairs
        andalso RepairOutput =/= undefined,
    case WantsRepair andalso llm_budget_available(TaskId, Data) of
        true ->
            Task1 = Task#{repair_count => RepairCount + 1},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
            RepairLlm = #{directive => proposal,
                          output => RepairOutput,
                          repair_output => RepairOutput},
            Data2 = start_llm_call(RepairLlm, TaskId, CorrelationId, Data1),
            {keep_state, Data2};
        false when WantsRepair ->
            %% Repair was wanted but the only thing blocking it is the budget's
            %% `max_llm_calls' cap: the repair attempt counts as one LLM call, so
            %% refusing it before the worker starts means the task fails with the
            %% budget reason -- not the parse diagnostics. The actor stays alive.
            Data1 = fail_task(TaskId, {budget_exceeded, max_llm_calls}, Data),
            {keep_state, Data1};
        false ->
            Task1 = Task#{status => failed, reason => Diagnostics},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
            emit(Data1, <<"actor.task.failed">>,
                 #{task_id => TaskId, correlation_id => CorrelationId,
                   reason => Diagnostics}),
            reply_waiter(TaskId, {error, Diagnostics}, Data1)
    end.

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
            start_owned_run(Steps, TaskId, CorrelationId, Data);
        _ ->
            Data
    end.

%% True when an approved `run_steps' proposal's step count is within the budget's
%% `max_steps' cap. An absent `max_steps' (or absent budget) means no cap on that
%% dimension, so any step count is available. The cap is a ceiling: a count over
%% it is refused; a count equal to it is allowed.
steps_budget_available(Steps, Data) ->
    case maps:get(max_steps, Data#data.budget, undefined) of
        undefined ->
            true;
        Max ->
            length(Steps) =< Max
    end.

%% Execute an approved, within-budget `run_steps' proposal: emit
%% `proposal.executed' at the point the actor hands the proposal off to a run --
%% the actor saying "I approved this and am starting a run for it", distinct from
%% the run's own `run.started'. It carries the task's correlation_id and
%% llm_call_id like the other proposal events, so by_correlation/2 returns the
%% full chain under one id. Then start the run via the shared owned-and-monitored
%% path; the existing run-terminal clauses store the step outputs and complete the
%% task, replying any parked waiter from the run's completion, not here.
execute_run_steps(Steps, TaskId, CorrelationId, LlmCallId, Proposal, Data) ->
    emit(Data, <<"proposal.executed">>,
         #{task_id => TaskId,
           correlation_id => CorrelationId,
           llm_call_id => LlmCallId,
           kind => maps:get(kind, Proposal, undefined)}),
    Data1 = start_owned_run(Steps, TaskId, CorrelationId, Data),
    {keep_state, Data1}.

%% Execute an approved `actor_message' proposal: deliver the proposal's payload
%% to the actor its `to' pid names. Emit `proposal.executed' (the sender saying
%% "I approved this and am delivering it", carrying the task's correlation_id and
%% llm_call_id like the run_steps path). Build a delivery envelope stamped with
%% the sender's correlation_id so the receiver's task lands under the same id, and
%% hand it to the receiver through the normal soma_actor:send/2 entry point -- no
%% layer bypassed, fire-and-forget (the sender does not wait on the receiver's
%% result). A delivery to a dead receiver exits the gen_statem:call inside send/2;
%% that exit is task data, not a sender crash, so it is caught and the sender task
%% is marked `failed'. On a successful delivery the sender task reaches `completed'
%% with the proposal as its result, releasing any parked ask waiter.
execute_actor_message(TaskId, CorrelationId, LlmCallId, Proposal, Data) ->
    emit(Data, <<"proposal.executed">>,
         #{task_id => TaskId,
           correlation_id => CorrelationId,
           llm_call_id => LlmCallId,
           kind => maps:get(kind, Proposal, undefined)}),
    To = maps:get(to, Proposal),
    Payload = maps:get(payload, Proposal),
    %% Branch on the body's shape. A map body builds the v0.5.6 delivery
    %% envelope byte-for-byte and goes down send/2's map clause. A Lisp string
    %% body (binary or iolist) is handed to send/2 as a string, so the receiver
    %% compiles it through soma_lfe:compile/2 at its own string clause (the L.1
    %% path) -- Lisp is parsed only at the receiving boundary. The sender's
    %% correlation_id has to ride along either way: the map delivery carries it
    %% as a wrapper field; the Lisp source gets a `(correlation-id "...")' form
    %% appended (Option 2 in the design) so the receiver's parse picks it up and
    %% by_correlation/2 still spans both actors.
    Delivery = build_delivery(Payload, CorrelationId),
    try soma_actor:send(To, Delivery) of
        {error, Reason} ->
            %% A malformed Lisp body fails the receiver's send/2 string clause
            %% (soma_lfe:compile/2 returns `{error, _}') before the receiver
            %% process is reached, so no receiver task is ever created. Record the
            %% failed delivery as the sender task's data: mark it `failed', emit
            %% `actor.task.failed', release any parked waiter, and stay alive.
            Data1 = fail_task(TaskId, {delivery_failed, Reason}, Data),
            {keep_state, Data1};
        _ ->
            Task = (maps:get(TaskId, Data#data.tasks))#{
                     status => completed, result => Proposal},
            Tasks = maps:put(TaskId, Task, Data#data.tasks),
            reply_waiter(TaskId, {ok, Proposal}, Data#data{tasks = Tasks})
    catch
        exit:Reason ->
            %% The receiver was dead (or otherwise unreachable) when send/2 ran.
            %% Treat the failed delivery as task data: mark the sender task
            %% `failed', emit `actor.task.failed', release any parked waiter, and
            %% stay alive -- the sender must survive a dead receiver.
            Data1 = fail_task(TaskId, {delivery_failed, Reason}, Data),
            {keep_state, Data1}
    end.

%% Build the delivery the sender hands to soma_actor:send/2, branching on the
%% body's shape. A Lisp string body (binary or iolist) is delivered as a string
%% with the sender's `(correlation-id "...")' appended -- the receiver parses it
%% at its own send/2 string clause (the L.1 path). A map body that is already a
%% full envelope (carrying `type' and `payload') is delivered as that envelope,
%% stamped with the sender's correlation_id, so its steps run on the receiver --
%% the map counterpart of the Lisp `(msg ...)' body. Any other map (the v0.5.6
%% plain payload, no `type') is wrapped in the fixed `actor.message' envelope
%% exactly as before, so the v0.5.6 delivery path is unchanged.
build_delivery(Payload, CorrelationId) when is_binary(Payload);
                                            is_list(Payload) ->
    append_correlation_id(Payload, CorrelationId);
build_delivery(Payload, CorrelationId) when is_map(Payload) ->
    case maps:is_key(type, Payload) andalso maps:is_key(payload, Payload) of
        true ->
            Payload#{correlation_id => CorrelationId};
        false ->
            #{type => <<"actor.message">>,
              payload => Payload,
              correlation_id => CorrelationId}
    end.

%% Append a `(correlation-id "Id")' form to a Lisp `(msg ...)' source, just inside
%% its closing paren, so the receiver's soma_lfe:compile/2 picks the sender's id
%% up and the delivered task lands under it. parse_msg_fields folds fields left to
%% right, so an appended id wins over any the body already carried -- the sender's
%% id should override, matching the map path where the wrapper id wins. The source
%% may be a binary or an iolist; it is flattened to a binary first.
append_correlation_id(Source, CorrelationId) ->
    Bin = iolist_to_binary(Source),
    Trimmed = trim_trailing_ws(Bin),
    Size = byte_size(Trimmed),
    case Trimmed of
        <<Body:(Size - 1)/binary, $)>> ->
            <<Body/binary, " (correlation-id \"", CorrelationId/binary,
              "\")", $)>>;
        _ ->
            %% No closing paren to insert before (a malformed body): hand it
            %% through unchanged, so soma_lfe:compile/2 reports the parse error at
            %% the receiver's send/2 rather than this helper masking it.
            Bin
    end.

%% Drop trailing whitespace bytes so the appended form sits just before the final
%% `)' of the `(msg ...)' source.
trim_trailing_ws(Bin) ->
    Size = byte_size(Bin),
    case Size of
        0 ->
            Bin;
        _ ->
            case binary:at(Bin, Size - 1) of
                C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
                    trim_trailing_ws(binary:part(Bin, 0, Size - 1));
                _ ->
                    Bin
            end
    end.

%% Start a soma_run the actor owns (session_pid => self()) for the given steps,
%% monitor it, track run_id => task_id, and set the task `running'. Shared by the
%% direct `steps' envelope path (maybe_start_run/4) and the approved `run_steps'
%% proposal path, so both inherit one set of run-ownership and failure semantics.
start_owned_run(Steps, TaskId, CorrelationId, Data) ->
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
    Data#data{runs = Runs, tasks = Tasks, monitors = Monitors}.

%% When the envelope carries an `llm' directive map, start a soma_llm_call worker
%% the actor owns directly (owner => self()), mirroring soma_run -> soma_tool_call:
%% the worker runs in its own process so its pid is distinct from the actor pid.
%% The actor mints an `llm_call_id', monitors the worker, tracks llm_call_id =>
%% task_id, records the task running, and emits `llm.started' carrying the worker
%% pid. With no `llm' field this is a no-op.
%% @doc Pure builder: turn the actor's `model_config' plus the incoming envelope
%% into the `llm' opts the worker runs. A real-provider config
%% (`#{provider => openai_compat, base_url, model}') becomes opts carrying
%% `provider => openai_compat' together with that `base_url' and `model' -- the
%% keys `soma_llm_call:perform_call/1' routes on to reach `soma_llm_openai'.
build_call_opts(#{provider := openai_compat,
                  base_url := BaseUrl,
                  model := Model} = _ModelConfig, _Envelope) ->
    #{provider => openai_compat,
      base_url => BaseUrl,
      model => Model}.

maybe_start_llm_call(Envelope, TaskId, CorrelationId, Data) ->
    case maps:get(llm, Envelope, undefined) of
        Llm when is_map(Llm) ->
            case llm_budget_available(TaskId, Data) of
                true ->
                    start_llm_call(Llm, TaskId, CorrelationId, Data);
                false ->
                    %% Spend point one: the task's LLM-call count is at the
                    %% max_llm_calls cap, so no call is made. The task fails as
                    %% data through the shared failure path; no llm.started fires.
                    fail_task(TaskId, {budget_exceeded, max_llm_calls}, Data)
            end;
        _ ->
            Data
    end.

%% True when the task's started-LLM-call count is below the budget's
%% `max_llm_calls' cap. An absent `max_llm_calls' (or absent budget) means no
%% cap on that dimension, so the call is always available.
llm_budget_available(TaskId, Data) ->
    case maps:get(max_llm_calls, Data#data.budget, undefined) of
        undefined ->
            true;
        Max ->
            Count = maps:get(TaskId, Data#data.llm_call_counts, 0),
            Count < Max
    end.

%% Fail a task as data through the existing failure shape: record `status =>
%% failed' with the reason, emit `actor.task.failed' carrying the reason, and
%% release any parked ask waiter with `{error, Reason}'. The actor stays alive.
fail_task(TaskId, Reason, Data) ->
    Task = maps:get(TaskId, Data#data.tasks),
    CorrelationId = maps:get(correlation_id, Task),
    Task1 = Task#{status => failed, reason => Reason},
    Tasks = maps:put(TaskId, Task1, Data#data.tasks),
    Data1 = Data#data{tasks = Tasks},
    emit(Data1, <<"actor.task.failed">>,
         #{task_id => TaskId, correlation_id => CorrelationId,
           reason => Reason}),
    %% Release any parked ask waiter directly: fail_task returns plain `#data'
    %% (it is called from maybe_start_llm_call/4, off the gen_statem return
    %% path), so a `{reply, From, _}' action threaded back through reply_waiter
    %% would be dropped by the caller. Reply via gen_statem:reply/2 and drop the
    %% waiter here so the parked `llm'-budget caller gets `{error, Reason}'
    %% instead of blocking until its timeout.
    case maps:get(TaskId, Data1#data.waiters, undefined) of
        undefined ->
            Data1;
        From ->
            gen_statem:reply(From, {error, Reason}),
            Data1#data{waiters = maps:remove(TaskId, Data1#data.waiters)}
    end.

start_llm_call(Llm, TaskId, CorrelationId, Data) ->
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
                  llm_timer_ref => TimerRef,
                  llm_directive => maps:get(directive, Llm, undefined),
                  repair_output => maps:get(repair_output, Llm, undefined)},
    Tasks = maps:put(TaskId, Task1, Data#data.tasks),
    %% The count increments only when a call actually starts, so it tracks the
    %% task's started-call total against the max_llm_calls cap.
    Count = maps:get(TaskId, Data#data.llm_call_counts, 0),
    Counts = maps:put(TaskId, Count + 1, Data#data.llm_call_counts),
    Data1 = Data#data{llm_calls = LlmCalls, tasks = Tasks,
                      monitors = Monitors, llm_call_counts = Counts},
    emit(Data1, <<"llm.started">>,
         #{task_id => TaskId, correlation_id => CorrelationId,
           llm_call_id => LlmCallId, llm_call_pid => WorkerPid}),
    Data1.

%% Decide a task result from a successful worker output. A proposal candidate -- a
%% map carrying a `kind' tag -- is validated through soma_proposal:normalize/1 and,
%% on success, its normalized form becomes the result tagged `{proposal, _}' so the
%% caller emits `proposal.created'. Any other output is opaque (the v0.5.1
%% contract: a `success' directive's output is stored verbatim) and tagged
%% `{opaque, _}' so no proposal event fires.
proposal_result(Output, _Directive) when is_map(Output) ->
    case maps:is_key(kind, Output) of
        true ->
            case soma_proposal:normalize(Output) of
                {ok, Proposal} -> {proposal, Proposal};
                {error, Diagnostics} -> {invalid_proposal, Diagnostics}
            end;
        false ->
            {opaque, Output}
    end;
%% A `proposal' directive's output that is a binary/string is a Lisp s-expr
%% proposal: parse it at the actor edge through soma_lfe:compile/2 into the same
%% `#{kind => ...}' map the raw-map path feeds to soma_proposal:normalize/1, then
%% run it through the same normalize path. A parse error tags
%% `{invalid_proposal, _}', reusing the failed-normalize handling. Gated on the
%% `proposal' directive because the v0.5 `success' directive also returns a
%% binary `output' that must stay opaque -- only a proposal is parsed as Lisp.
proposal_result(Output, proposal) when is_binary(Output); is_list(Output) ->
    case soma_lfe:compile(Output, #{}) of
        {ok, ProposalMap} ->
            case soma_proposal:normalize(ProposalMap) of
                {ok, Proposal} -> {proposal, Proposal};
                {error, Diagnostics} -> {invalid_proposal, Diagnostics}
            end;
        {error, Diagnostics} ->
            {invalid_proposal, Diagnostics}
    end;
proposal_result(Output, _Directive) ->
    {opaque, Output}.

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
            _ = erlang:cancel_timer(TimerRef, [{async, false}, {info, false}]),
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
