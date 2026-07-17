%% @doc One execution attempt for a run, as a `gen_statem'. v0.1 happy path: a
%% run starts under `soma_run_sup', records `run.started', then drives its step
%% list strictly sequentially. For each step it records `step.started' and
%% `tool.started', starts a `soma_tool_call' worker, and waits in
%% `waiting_tool' for that worker's result before touching the next step. On a
%% successful invocation it records `tool.succeeded' and `step.succeeded',
%% stores the output, and advances. When the cursor passes the last step it
%% records `run.completed' and reaches the `completed' state.
-module(soma_run).

-behaviour(gen_statem).

-export([start_link/1, activate/1, activate/2, activate_sync/3,
         prepare_start_sync/3,
         identity/1, identity/2,
         adopt_owner/2, adopt_owner/3]).
-export([callback_mode/0, init/1, terminate/3]).
-export([awaiting_start/3, executing/3, waiting_tool/3,
         completed/3, failed/3, timeout/3,
         cancelled/3]).

-record(data, {run_id,
               task_id,
               session_id,
               session_pid,
               correlation_id,
               request_id,
               envelope_hash,
               max_output_bytes,
               deadline_at_ms,
               auto_resume,
               run_origin,
               admission_required,
               admission_id,
               start_kind = started,
               start_prepared = false,
               start_lease_deadline_ms,
               session_mref,
               resume_descriptor_guard,
               event_store,
               steps = [],
               pending = [],
               outputs = #{},
               current,
               tool_call_id,
               worker_pid,
               worker_mref,
               os_pid}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% Resume starts use an acknowledgement barrier: the child exists and owns its
%% RunId but cannot execute a step until the recovery owner has observed the
%% successful supervisor start. Sending to a dead pid is harmless.
activate(Pid) when is_pid(Pid) ->
    activate(Pid, infinity).

activate(Pid, Deadline) when is_pid(Pid),
                             (Deadline =:= infinity orelse
                              is_integer(Deadline)) ->
    Pid ! {activate, Deadline},
    ok.

activate_sync(Pid, Deadline, Timeout)
  when is_pid(Pid),
       (Deadline =:= infinity orelse is_integer(Deadline)),
       (Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)) ->
    gen_statem:call(Pid, {activate_sync, Deadline}, Timeout).

prepare_start_sync(Pid, Deadline, Timeout)
  when is_pid(Pid),
       (Deadline =:= infinity orelse is_integer(Deadline)),
       (Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)) ->
    gen_statem:call(Pid, {prepare_start, Deadline}, Timeout).

identity(Pid) when is_pid(Pid) ->
    identity(Pid, infinity).

identity(Pid, Timeout) when is_pid(Pid) ->
    gen_statem:call(Pid, identity, Timeout).

adopt_owner(Pid, Owner) when is_pid(Pid), is_pid(Owner) ->
    adopt_owner(Pid, Owner, infinity).

adopt_owner(Pid, Owner, Timeout) when is_pid(Pid), is_pid(Owner) ->
    gen_statem:call(Pid, {adopt_owner, Owner}, Timeout).

callback_mode() ->
    state_functions.

init(Opts) ->
    %% Tool-call workers link back to their run so an unexpected run death also
    %% tears down the invocation. Trap those worker exits here; the existing
    %% monitor remains the authoritative result/crash protocol.
    process_flag(trap_exit, true),
    StartPaused = maps:get(start_paused, Opts, false),
    StartLeaseDeadline = maps:get(
                           start_lease_deadline_ms, Opts, undefined),
    case start_lease_live(StartPaused, StartLeaseDeadline) of
        false -> ignore;
        true -> init_live(Opts, StartPaused, StartLeaseDeadline)
    end.

init_live(Opts, StartPaused, StartLeaseDeadline) ->
    RunId = maps:get(run_id, Opts),
    %% Claim before the first durable event or tool boundary.  The separately
    %% supervised index survives a `soma_run_sup' generation change, so an old
    %% suspended child keeps its id fenced until that exact pid is dead.
    case claim_run_id(
           RunId, maps:get(run_supervisor_generation, Opts, undefined)) of
        ok -> ok;
        {error, ClaimReason} -> exit(ClaimReason)
    end,
    RunOrigin = normalize_run_origin(maps:get(run_origin, Opts, undefined)),
    AutoResume = normalize_auto_resume(
                   RunOrigin, maps:get(auto_resume, Opts, undefined)),
    AdmissionRequired = normalize_admission_required(
                          RunOrigin,
                          maps:get(admission_required, Opts, false)),
    AdmissionId = normalize_admission_id(
                    RunOrigin, AdmissionRequired,
                    maps:get(admission_id, Opts, undefined)),
    ok = ensure_admission_identity(AdmissionRequired, AdmissionId),
    SessionPid = maps:get(session_pid, Opts, undefined),
    SessionMRef = monitor_paused_owner(StartPaused, SessionPid),
    StartKind = case maps:is_key(pending, Opts) of
                    true -> resumed;
                    false -> started
                end,
    Data = #data{run_id = RunId,
                 task_id = maps:get(task_id, Opts, undefined),
                 session_id = maps:get(session_id, Opts, undefined),
                 session_pid = SessionPid,
                 correlation_id = maps:get(correlation_id, Opts, undefined),
                 request_id = maps:get(request_id, Opts, undefined),
                 envelope_hash = maps:get(envelope_hash, Opts, undefined),
                 max_output_bytes = maps:get(
                                      max_output_bytes, Opts, undefined),
                 deadline_at_ms = maps:get(
                                    deadline_at_ms, Opts, undefined),
                 auto_resume = AutoResume,
                 %% A fixed, internal ownership class may be journaled by an
                 %% edge owner that needs to reclaim its run after restart.
                 %% The runtime stores the value as data and never branches on
                 %% an edge-specific origin, preserving the one-way dependency.
                 run_origin = RunOrigin,
                 admission_required = AdmissionRequired,
                 admission_id = AdmissionId,
                 start_kind = StartKind,
                 start_lease_deadline_ms = StartLeaseDeadline,
                 session_mref = SessionMRef,
                 resume_descriptor_guard = maps:get(
                                             resume_descriptor_guard, Opts,
                                             undefined),
                 event_store = maps:get(event_store, Opts, undefined),
                 steps = maps:get(steps, Opts, []),
                 %% `pending' is the not-yet-committed suffix the state machine
                 %% walks. A resume start passes it omitting the already-committed
                 %% prefix; a normal start omits the opt, so it defaults to the
                 %% full `steps' list and the run begins at step 0 unchanged.
                 pending = maps:get(pending, Opts, maps:get(steps, Opts, [])),
                 %% `outputs' seeds the committed steps' recorded outputs keyed by
                 %% step id, so a pending step's `from_step' into a committed step
                 %% resolves. A normal start omits the opt and begins with `#{}'.
                 outputs = maps:get(outputs, Opts, #{})},
    %% A start is a resume when the caller supplies the `pending' opt: the
    %% reconstructed not-yet-committed suffix. A resume start opens with
    %% `run.resumed' (naming the first pending step) and deliberately does NOT
    %% re-emit `run.started', so the original journal stays the single source of
    %% truth `reconstruct' reads. A normal start (no `pending' opt) emits
    %% `run.started' with the same payload as before.
    case StartPaused of
        true ->
            %% The resume event itself is also behind the owner barrier. A
            %% cancellation committed while supervisor:start_child was
            %% in-doubt therefore produces neither run.resumed nor a tool
            %% boundary when the queued child eventually initializes.
            paused_start(Data);
        false ->
            emit_start_event(Data),
            {ok, executing, Data, [{next_event, internal, next_step}]}
    end.

emit_start_event(#data{start_kind = resumed} = Data) ->
    emit_resume_event(Data);
emit_start_event(#data{start_kind = started} = Data) ->
    emit(Data, <<"run.started">>,
         #{payload => #{steps => Data#data.steps,
                        run_options => durable_run_options(Data)}}).

emit_resume_event(Data) ->
    FirstPendingStep = first_pending_step(Data#data.pending),
    emit(Data, <<"run.resumed">>,
         #{step_id => FirstPendingStep,
           payload => #{first_pending_step => FirstPendingStep}}).

%% The step id of the first not-yet-committed step, or `undefined' when the
%% pending suffix is empty (a resume with nothing left to run).
first_pending_step([Step | _]) ->
    maps:get(id, Step);
first_pending_step([]) ->
    undefined.

%% A recovery child waits here until the owner receives start_child's
%% acknowledgement. If that acknowledgement times out after commit, the child
%% remains effect-free and discoverable through `soma_run_index'. Cancellation
%% is terminal directly from this state, so controlled stop cannot release a
%% queued resume into its first tool.
awaiting_start({call, From}, identity, Data) ->
    reply_identity(From, awaiting_start, Data);
awaiting_start({call, From}, {adopt_owner, Owner}, Data) ->
    adopt_paused_owner_reply(From, Owner, Data);
awaiting_start({call, From}, {prepare_start, _RequestDeadline},
               Data = #data{start_prepared = true}) ->
    {keep_state, Data, [{reply, From, ok}]};
awaiting_start({call, From}, {prepare_start, RequestDeadline}, Data) ->
    case commit_preparation(RequestDeadline, Data) of
        {ok, PreparedData} ->
            {keep_state, PreparedData, [{reply, From, ok}]};
        {error, start_lease_expired} ->
            {stop_and_reply, normal,
             [{reply, From, {error, start_lease_expired}}],
             clear_paused_owner_monitor(Data)}
    end;
awaiting_start({call, From}, {activate_sync, RequestDeadline}, Data) ->
    case finish_activation(RequestDeadline, Data) of
        {ok, ActiveData} ->
            {next_state, executing, ActiveData,
             [{reply, From, ok}, cancel_start_lease_action(),
              {next_event, internal, next_step}]};
        {error, start_lease_expired} ->
            {stop_and_reply, normal,
             [{reply, From, {error, start_lease_expired}}],
             clear_paused_owner_monitor(Data)}
    end;
awaiting_start(info, {activate, RequestDeadline}, Data) ->
    case finish_activation(RequestDeadline, Data) of
        {ok, ActiveData} ->
            {next_state, executing, ActiveData,
             [cancel_start_lease_action(),
              {next_event, internal, next_step}]};
        {error, start_lease_expired} ->
            {stop, normal, clear_paused_owner_monitor(Data)}
    end;
awaiting_start(info, cancel, Data) ->
    CancelledData = clear_paused_owner_monitor(Data),
    emit(CancelledData, <<"run.cancelled">>,
         #{payload => #{reason => cli_cancel}}),
    notify_session_cancelled(CancelledData),
    {next_state, cancelled, CancelledData};
awaiting_start({timeout, start_lease}, start_lease_expired, Data) ->
    {stop, normal, clear_paused_owner_monitor(Data)};
awaiting_start(info, {'DOWN', MRef, process, Owner, _Reason},
               Data = #data{session_pid = Owner, session_mref = MRef}) ->
    %% A queued supervisor start can initialize after the bounded owner has
    %% already died. It must disappear effect-free instead of becoming an
    %% ownerless paused claim that a later daemon generation cannot classify.
    {stop, normal, Data#data{session_mref = undefined}};
awaiting_start(info, {'EXIT', _Pid, normal}, Data) ->
    {keep_state, Data};
awaiting_start(info, {'EXIT', _Pid, Reason}, Data) ->
    {stop, Reason, Data};
awaiting_start(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% Drive the next step, or finish the run when none remain.
executing({call, From}, identity, Data) ->
    reply_identity(From, executing, Data);
executing({call, From}, {adopt_owner, Owner}, Data) ->
    adopt_owner_reply(From, Owner, Data);
executing(info, activate, Data) ->
    {keep_state, Data};
executing(info, {activate, _Deadline}, Data) ->
    {keep_state, Data};
executing(info, {'EXIT', _Pid, normal}, Data) ->
    {keep_state, Data};
executing(info, {'EXIT', _Pid, Reason}, Data) ->
    {stop, Reason, Data};
executing(internal, next_step, Data = #data{pending = []}) ->
    emit(Data, <<"run.completed">>, #{}),
    notify_session(Data),
    {next_state, completed, Data};
executing(internal, next_step, Data = #data{pending = [Step | _Rest]}) ->
    case validate_step(Step) of
        ok ->
            execute_valid_step(Data, Step);
        {error, Reason} ->
            fail_invalid_step(Data, Step, Reason)
    end.

execute_valid_step(Data, Step) ->
    StepId = maps:get(id, Step),
    ToolName = maps:get(tool, Step),
    Resolved = resolve_args(maps:get(args, Step, #{}), Data#data.outputs),
    {Input, CtxExtra} = split_ctx_args(Resolved),
    ToolCallId = new_tool_call_id(),
    emit(Data, <<"step.started">>,
         #{step_id => StepId, tool_call_id => ToolCallId}),
    case soma_tool_registry:resolve_descriptor(ToolName) of
        {error, not_found} ->
            %% The step names a tool that was never registered. Resolve fails
            %% before any worker is spawned, so there is no `tool_call_pid' to
            %% kill: reuse `fail_run/5' with `undefined' for the worker pid so the
            %% run lands in the same terminal `failed' state, with the same
            %% failure trail, as any other failure -- not a badmatch crash.
            fail_run(Data, Step, ToolCallId, undefined,
                     {unregistered_tool, ToolName});
        {ok, Descriptor0} ->
            %% Branch on the adapter the descriptor names. An `erlang_module'
            %% tool runs in-BEAM via `module'; a `cli' tool runs an external
            %% program via `executable' + `argv'. The worker owns the difference;
            %% `soma_run' only chooses which opts to hand it.
            case resume_descriptor_allowed(Data, StepId, Descriptor0) of
                {error, GuardReason} ->
                    fail_run(Data, Step, ToolCallId, undefined, GuardReason);
                ok ->
                    execute_resolved_descriptor(
                      Data, Step, StepId, ToolCallId, Descriptor0,
                      Input, CtxExtra)
            end
    end.

execute_resolved_descriptor(
  Data, Step, StepId, ToolCallId, Descriptor0, Input, CtxExtra) ->
    case prepare_cli_argv_placeholders(Descriptor0, Input) of
        {error, Reason} ->
                    %% A `cli' argv placeholder names a key the resolved step
                    %% input does not carry (`missing_cli_placeholder'), or its
                    %% value does not match the declared param type
                    %% (`invalid_cli_placeholder_value'). Both fail before any
                    %% worker is spawned, exactly like an unregistered tool:
                    %% reuse `fail_run/5' with `undefined' for the worker pid so
                    %% there is no `tool.started' event for this step.
            fail_run(Data, Step, ToolCallId, undefined, Reason);
        Descriptor ->
            start_tool_call(Data, Step, StepId, ToolCallId, Descriptor,
                            Input, CtxExtra)
    end.

resume_descriptor_allowed(#data{resume_descriptor_guard = undefined},
                          _StepId, _Descriptor) ->
    ok;
resume_descriptor_allowed(
  #data{resume_descriptor_guard =
            #{step_id := StepId, descriptor := Descriptor}},
  StepId, Descriptor) ->
    ok;
resume_descriptor_allowed(
  #data{resume_descriptor_guard = #{step_id := StepId}}, StepId,
  _ChangedDescriptor) ->
    {error, resume_descriptor_changed};
resume_descriptor_allowed(_Data, _StepId, _Descriptor) ->
    {error, resume_descriptor_guard_mismatch}.

%% Spawn the tool-call worker for a resolved tool, record `tool.started', arm the
%% per-step timer, and move to `waiting_tool'.
start_tool_call(Data, Step, StepId, ToolCallId, Descriptor, Input, CtxExtra) ->
    BaseCtx = add_optional(correlation_id, Data#data.correlation_id,
                           #{session_id => Data#data.session_id,
                             run_id => Data#data.run_id,
                             step_id => StepId,
                             tool_call_id => ToolCallId}),
    Ctx = maps:merge(CtxExtra, BaseCtx),
    AdapterOpts = adapter_opts(Descriptor),
    WorkerOpts = AdapterOpts#{input => Input,
                              ctx => Ctx,
                              tool_call_id => ToolCallId,
                              reply_to => self()},
    {ok, WorkerPid, MRef} = soma_tool_call:start(WorkerOpts),
    %% Record `tool.started' after the worker is spawned so the event carries the
    %% worker pid: the run can prove each invocation ran in its own process, and
    %% the timeout/cancel paths give a test the pid to confirm the worker died.
    emit(Data, <<"tool.started">>,
         #{step_id => StepId, tool_call_id => ToolCallId,
           tool_call_pid => WorkerPid,
           %% Persist the repeat-safety facts used for this invocation. Resume
           %% requires both this original snapshot and the current descriptor
           %% to be safe, so editing a manifest after a crash cannot soften an
           %% in-flight non-idempotent action into a retryable one.
           payload => #{resume_safety =>
                            maps:with([effect, idempotent], Descriptor)}}),
    %% Cross back through the mailbox before releasing the worker. A cancel
    %% that arrived while the durable append was blocked is already ahead of
    %% this message and therefore kills the still-paused worker before any
    %% tool effect can begin.
    self() ! {invoke_tool, ToolCallId, WorkerPid},
    %% Arm a per-step timer when the step asks for one. A `gen_statem' state
    %% timeout fits: if the reply comes first, leaving `waiting_tool' cancels
    %% the timer; if the timer fires first, `waiting_tool' gets `step_timeout'
    %% while the worker pid is still known. A step with no `timeout_ms' gets no
    %% timer, matching the unbounded wait for steps that don't ask for one.
    NewData = Data#data{current = Step, tool_call_id = ToolCallId,
                        worker_pid = WorkerPid, worker_mref = MRef},
    case maps:get(timeout_ms, Step, undefined) of
        undefined ->
            {next_state, waiting_tool, NewData};
        TimeoutMs ->
            {next_state, waiting_tool, NewData,
             [{state_timeout, TimeoutMs, step_timeout}]}
    end.

%% A `cli' worker reports the OS pid of the external process it just spawned.
%% Record it so the timeout/cancel teardown can kill the external process, not
%% just the BEAM worker. An `erlang_module' worker never sends this, so the
%% stored pid stays `undefined' and the in-BEAM teardown is unchanged.
waiting_tool({call, From}, identity, Data) ->
    reply_identity(From, waiting_tool, Data);
waiting_tool({call, From}, {adopt_owner, Owner}, Data) ->
    adopt_owner_reply(From, Owner, Data);
waiting_tool(info, activate, Data) ->
    {keep_state, Data};
waiting_tool(info, {activate, _Deadline}, Data) ->
    {keep_state, Data};
waiting_tool(info, {invoke_tool, ToolCallId, WorkerPid},
             Data = #data{tool_call_id = ToolCallId,
                          worker_pid = WorkerPid}) ->
    ok = soma_tool_call:invoke(WorkerPid),
    {keep_state, Data};
%% The worker is both linked and monitored. Its link makes ownership real when
%% the run dies; while the run is alive, ignore the linked exit and let the
%% monitor clause below preserve the exact worker crash reason.
waiting_tool(info, {'EXIT', WorkerPid, _Reason},
             Data = #data{worker_pid = WorkerPid}) ->
    {keep_state, Data};
waiting_tool(info, {'EXIT', _Pid, normal}, Data) ->
    {keep_state, Data};
waiting_tool(info, {'EXIT', _Pid, Reason}, Data) ->
    {stop, Reason, Data};
waiting_tool(info, {tool_started_os_pid, ToolCallId, _WorkerPid, OsPid},
             Data = #data{tool_call_id = ToolCallId}) ->
    {keep_state, Data#data{os_pid = OsPid}};
%% Wait for the active tool-call worker's result; only then advance.
waiting_tool(info, {tool_result, ToolCallId, WorkerPid, {ok, Output}},
             Data = #data{tool_call_id = ToolCallId,
                          current = Step,
                          pending = [Step | Rest],
                          outputs = Outputs,
                          worker_mref = MRef}) ->
    %% The worker exits `normal' right after this reply. Demonitor-and-flush so
    %% its clean `'DOWN'' never reaches the crash clause and is not mistaken for
    %% a failure.
    demonitor_flush(MRef),
    StepId = maps:get(id, Step),
    emit(Data, <<"tool.succeeded">>,
         #{step_id => StepId, tool_call_id => ToolCallId,
           tool_call_pid => WorkerPid}),
    emit(Data, <<"step.succeeded">>,
         #{step_id => StepId, tool_call_id => ToolCallId,
           payload => #{output => Output}}),
    NewData = Data#data{pending = Rest,
                        outputs = Outputs#{StepId => Output},
                        resume_descriptor_guard = undefined,
                        current = undefined,
                        tool_call_id = undefined,
                        worker_pid = undefined,
                        worker_mref = undefined,
                        os_pid = undefined},
    {next_state, executing, NewData, [{next_event, internal, next_step}]};
%% The tool returned an error: record the failure trail and move to `failed'.
%% A crash and an `{error, _}' return land in the same terminal state.
waiting_tool(info, {tool_result, ToolCallId, WorkerPid, {error, Reason}},
             Data = #data{tool_call_id = ToolCallId, current = Step,
                          worker_mref = MRef}) ->
    demonitor_flush(MRef),
    fail_run(Data, Step, ToolCallId, WorkerPid, Reason);
%% The tool-call worker crashed: the tool raised and the process died without
%% replying. The monitor delivers `'DOWN'' with a non-`normal' reason. A crash
%% and an `{error, _}' return land in the same terminal `failed' state.
waiting_tool(info, {'DOWN', MRef, process, WorkerPid, Reason},
             Data = #data{worker_mref = MRef, current = Step,
                          tool_call_id = ToolCallId})
  when Reason =/= normal ->
    fail_run(Data, Step, ToolCallId, WorkerPid, Reason);
%% The step ran longer than its `timeout_ms': the state timer fired before the
%% reply. Kill the active worker, record `run.timeout', tell the session, and
%% move to the `timeout' state. The brutal kill makes cancellation real rather
%% than a flag checked later.
waiting_tool(state_timeout, step_timeout,
             Data = #data{worker_pid = WorkerPid, worker_mref = MRef,
                          current = Step, tool_call_id = ToolCallId,
                          os_pid = OsPid}) ->
    demonitor_flush(MRef),
    exit(WorkerPid, kill),
    soma_os_process:kill(OsPid),
    emit(Data, <<"run.timeout">>,
         #{step_id => maps:get(id, Step), tool_call_id => ToolCallId}),
    notify_session_timeout(Data),
    {next_state, timeout, Data#data{current = undefined,
                                    tool_call_id = undefined,
                                    worker_pid = undefined,
                                    worker_mref = undefined,
                                    os_pid = undefined}};
%% The run was cancelled: the session forwarded a `cancel' while the run waited
%% on its active worker. Kill that worker, record `run.cancelled', tell the
%% session, and move to the `cancelled' state. The brutal kill makes
%% cancellation real rather than a flag checked at the end.
waiting_tool(info, cancel,
             Data = #data{worker_pid = WorkerPid, worker_mref = MRef,
                          current = Step, tool_call_id = ToolCallId,
                          os_pid = OsPid}) ->
    demonitor_flush(MRef),
    exit(WorkerPid, kill),
    soma_os_process:kill(OsPid),
    emit(Data, <<"run.cancelled">>,
         #{step_id => maps:get(id, Step), tool_call_id => ToolCallId}),
    notify_session_cancelled(Data),
    {next_state, cancelled, Data#data{current = undefined,
                                      tool_call_id = undefined,
                                      worker_pid = undefined,
                                      worker_mref = undefined,
                                      os_pid = undefined}}.

completed({call, From}, identity, Data) ->
    reply_identity(From, completed, Data);
completed({call, From}, {adopt_owner, _Owner}, Data) ->
    terminal_adoption_reply(From, completed, Data);
completed(_EventType, _Event, Data) ->
    {keep_state, Data}.

failed({call, From}, identity, Data) ->
    reply_identity(From, failed, Data);
failed({call, From}, {adopt_owner, _Owner}, Data) ->
    terminal_adoption_reply(From, failed, Data);
failed(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% Terminal `timeout' state: the run stays alive holding its final state, like
%% `completed/3'. A stray `'DOWN'' from the worker the timeout killed is just
%% noise here and is ignored.
timeout({call, From}, identity, Data) ->
    reply_identity(From, timeout, Data);
timeout({call, From}, {adopt_owner, _Owner}, Data) ->
    terminal_adoption_reply(From, timeout, Data);
timeout(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% Terminal `cancelled' state: the run stays alive holding its final state, like
%% `completed/3'. A stray `'DOWN'' from the worker the cancel killed is just
%% noise here and is ignored.
cancelled({call, From}, identity, Data) ->
    reply_identity(From, cancelled, Data);
cancelled({call, From}, {adopt_owner, _Owner}, Data) ->
    terminal_adoption_reply(From, cancelled, Data);
cancelled(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% A graceful abnormal stop (including a trapped direct exit signal) cleans the
%% invocation synchronously before the service can observe this run's `DOWN'.
%% The worker link covers the untrappable `kill' case, where terminate/3 cannot
%% run at all.
terminate(_Reason, _State,
          #data{worker_pid = WorkerPid,
                worker_mref = MRef,
                os_pid = OsPid})
  when is_pid(WorkerPid), is_reference(MRef) ->
    soma_os_process:kill(OsPid),
    exit(WorkerPid, kill),
    await_worker_down(MRef, WorkerPid),
    ok;
terminate(_Reason, _State, _Data) ->
    ok.

%%% Internal

reply_identity(From, Status, Data) ->
    {keep_state, Data,
     [{reply, From, {ok, #{run_id => Data#data.run_id,
                          status => Status}}}]}.

adopt_owner_reply(From, Owner, Data) ->
    {keep_state, Data#data{session_pid = Owner},
     [{reply, From, ok}]}.

adopt_paused_owner_reply(From, Owner, Data) ->
    Cleared = clear_paused_owner_monitor(Data),
    MRef = erlang:monitor(process, Owner),
    {keep_state, Cleared#data{session_pid = Owner, session_mref = MRef},
     [{reply, From, ok}]}.

paused_start(#data{start_lease_deadline_ms = undefined} = Data) ->
    {ok, awaiting_start, Data};
paused_start(#data{start_lease_deadline_ms = Deadline} = Data) ->
    {ok, awaiting_start, Data,
     [{{timeout, start_lease}, remaining_ms(Deadline),
       start_lease_expired}]}.

cancel_start_lease_action() ->
    {{timeout, start_lease}, cancel}.

start_lease_live(false, _Deadline) ->
    true;
start_lease_live(true, undefined) ->
    true;
start_lease_live(true, Deadline) when is_integer(Deadline) ->
    remaining_ms(Deadline) > 0.

monitor_paused_owner(true, Owner) when is_pid(Owner) ->
    erlang:monitor(process, Owner);
monitor_paused_owner(_StartPaused, _Owner) ->
    undefined.

clear_paused_owner_monitor(Data = #data{session_mref = MRef}) ->
    demonitor_flush(MRef),
    Data#data{session_mref = undefined}.

activation_live(RequestDeadline,
                #data{start_lease_deadline_ms = LeaseDeadline}) ->
    deadline_live(RequestDeadline) andalso deadline_live(LeaseDeadline).

commit_activation(RequestDeadline, Data) ->
    case activation_authorized(RequestDeadline, Data) of
        false ->
            {error, start_lease_expired};
        true ->
            %% `emit_start_event' is the admission commit barrier. Re-check the
            %% absolute lease and paused owner after the synchronous durable
            %% append: a blocked store must not release an expired request into
            %% its first tool merely because activation began before deadline.
            emit_start_event(Data),
            case activation_authorized(RequestDeadline, Data) of
                true -> {ok, clear_paused_owner_monitor(Data)};
                false ->
                    %% The durable start/resume event may already have landed.
                    %% Close that journal in the same process before stopping,
                    %% otherwise a later owner could mistake an admission that
                    %% never completed for resumable work.
                    emit(Data, <<"run.cancelled">>,
                         #{payload => #{reason => start_lease_expired}}),
                    notify_session_cancelled(Data),
                    {error, start_lease_expired}
            end
    end.

commit_preparation(RequestDeadline, Data) ->
    case activation_authorized(RequestDeadline, Data) of
        false ->
            {error, start_lease_expired};
        true ->
            emit_start_event(Data),
            case activation_authorized(RequestDeadline, Data) of
                true ->
                    %% Preparation durably records run.started but keeps both
                    %% the owner monitor and worker boundary closed. The edge
                    %% owner must write its admission proof before activation.
                    {ok, Data#data{start_prepared = true}};
                false ->
                    emit(Data, <<"run.cancelled">>,
                         #{payload => #{reason => start_lease_expired}}),
                    notify_session_cancelled(Data),
                    {error, start_lease_expired}
            end
    end.

finish_activation(RequestDeadline,
                  Data = #data{start_prepared = true,
                               admission_required = true}) ->
    commit_prepared_admission(RequestDeadline, Data);
finish_activation(RequestDeadline,
                  Data = #data{start_prepared = true}) ->
    case activation_authorized(RequestDeadline, Data) of
        true -> {ok, clear_paused_owner_monitor(Data)};
        false -> {error, start_lease_expired}
    end;
finish_activation(RequestDeadline, Data) ->
    commit_activation(RequestDeadline, Data).

%% `cli.task.accepted' records the edge owner's intention. This run-owned
%% marker is the execution commit: it can only be emitted after the paused
%% child has observed activation from its still-live owner, and it is durable
%% before the first step or tool boundary. Recovery requires both markers, so
%% an accepted append that lands after its old owner/run died cannot authorize
%% a fresh attempt by itself.
commit_prepared_admission(RequestDeadline,
                          Data = #data{admission_id = AdmissionId}) ->
    case activation_authorized(RequestDeadline, Data) of
        false ->
            {error, start_lease_expired};
        true ->
            emit(Data, <<"run.admission.committed">>,
                 #{task_id => Data#data.task_id,
                   payload => #{admission_protocol => cli_detached_v1,
                                admission_id => AdmissionId}}),
            case activation_authorized(RequestDeadline, Data) of
                true ->
                    {ok, clear_paused_owner_monitor(Data)};
                false ->
                    emit(Data, <<"run.cancelled">>,
                         #{payload => #{reason => start_lease_expired}}),
                    notify_session_cancelled(Data),
                    {error, start_lease_expired}
            end
    end.

activation_authorized(RequestDeadline, Data) ->
    activation_live(RequestDeadline, Data) andalso paused_owner_live(Data).

paused_owner_live(#data{session_pid = Owner, session_mref = MRef})
  when is_pid(Owner), is_reference(MRef) ->
    is_process_alive(Owner);
paused_owner_live(_Data) ->
    true.

deadline_live(infinity) ->
    true;
deadline_live(undefined) ->
    true;
deadline_live(Deadline) when is_integer(Deadline) ->
    remaining_ms(Deadline) > 0.

remaining_ms(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

terminal_adoption_reply(From, Status, Data) ->
    {keep_state, Data,
     [{reply, From, {error, {terminal, Status}}}]}.

%% Translate a resolved descriptor into the worker opts that name how to run it.
%% An `erlang_module' descriptor hands the worker its backing `module'; a `cli'
%% descriptor hands it the `executable' and `argv' so the worker opens a port.
adapter_opts(#{adapter := erlang_module, module := Module}) ->
    #{module => Module};
adapter_opts(#{adapter := cli, executable := Executable, argv := Argv,
               append_input := AppendInput}) ->
    #{executable => Executable, argv => Argv, append_input => AppendInput};
adapter_opts(#{adapter := cli, executable := Executable, argv := Argv}) ->
    #{executable => Executable, argv => Argv}.

prepare_cli_argv_placeholders(#{adapter := cli, argv := Argv} = Descriptor,
                              Input)
  when is_map(Input) ->
    Lookup = cli_placeholder_lookup(Input),
    Types = cli_placeholder_types(Descriptor),
    case render_cli_argv(Argv, Lookup, Types) of
        {error, _} = Error ->
            Error;
        {ok, RenderedArgv} ->
            Prepared = Descriptor#{argv := RenderedArgv},
            case cli_argv_has_placeholder(Argv) of
                true -> Prepared#{append_input => false};
                false -> Prepared
            end
    end;
prepare_cli_argv_placeholders(Descriptor, _Input) ->
    Descriptor.

%% Render every argv element, short-circuiting on the first placeholder whose
%% key is absent from the resolved step input or whose value does not match
%% the declared param type. Neither can become a worker argv element -- each is
%% reported to the caller as a named failure instead, so the run can fail
%% before any worker is spawned.
render_cli_argv(Argv, Lookup, Types) ->
    render_cli_argv(Argv, Lookup, Types, []).

render_cli_argv([], _Lookup, _Types, Acc) ->
    {ok, lists:reverse(Acc)};
render_cli_argv([Arg | Rest], Lookup, Types, Acc) ->
    case render_cli_argv_placeholder(Arg, Lookup, Types) of
        {error, _} = Error -> Error;
        Rendered -> render_cli_argv(Rest, Lookup, Types, [Rendered | Acc])
    end.

cli_argv_has_placeholder([]) ->
    false;
cli_argv_has_placeholder([Arg | Rest]) ->
    case cli_argv_placeholder_name(Arg) of
        {placeholder, _Name} -> true;
        none -> cli_argv_has_placeholder(Rest)
    end.

cli_placeholder_lookup(Input) ->
    maps:fold(
      fun(Key, Value, Acc) ->
              case cli_placeholder_key(Key) of
                  {ok, Name} -> Acc#{Name => Value};
                  error -> Acc
              end
      end,
      #{},
      Input).

cli_placeholder_key(Key) when is_atom(Key) ->
    {ok, atom_to_binary(Key, utf8)};
cli_placeholder_key(Key) when is_binary(Key) ->
    {ok, Key};
cli_placeholder_key(_Key) ->
    error.

render_cli_argv_placeholder(Arg, Lookup, Types) ->
    case cli_argv_placeholder_name(Arg) of
        {placeholder, Name} ->
            case maps:find(Name, Lookup) of
                {ok, Value} ->
                    render_cli_placeholder_value(
                        Name, maps:get(Name, Types, undefined), Value);
                error -> {error, {missing_cli_placeholder, Name}}
            end;
        none ->
            Arg
    end.

%% The declared param types of a cli descriptor, keyed by placeholder name.
%% Normalization guarantees every argv placeholder is declared in `params',
%% so a lookup miss can only mean a descriptor that bypassed that guarantee --
%% the typed renderer below then fails closed on the `undefined' type.
cli_placeholder_types(#{params := Params}) when is_list(Params) ->
    lists:foldl(
      fun(#{name := Name, type := Type}, Acc) when is_binary(Name) ->
              Acc#{Name => Type};
         (_Other, Acc) ->
              Acc
      end,
      #{},
      Params);
cli_placeholder_types(_Descriptor) ->
    #{}.

cli_argv_placeholder_name(Arg) when is_binary(Arg) ->
    Size = byte_size(Arg),
    case Size >= 2 andalso
        binary:at(Arg, 0) =:= ${ andalso
        binary:at(Arg, Size - 1) =:= $} of
        true ->
            NameSize = Size - 2,
            <<${, Name:NameSize/binary, $}>> = Arg,
            {placeholder, Name};
        false ->
            none
    end;
cli_argv_placeholder_name(Arg) ->
    try unicode:characters_to_binary(Arg) of
        Bin when is_binary(Bin) -> cli_argv_placeholder_name(Bin);
        _ -> none
    catch
        error:badarg -> none
    end.

%% Render a placeholder value by its declared param type. The declared type is
%% the contract: a `string' must be a binary or an Erlang string (kept
%% literal), an `integer' renders as base-10 decimal text, a `boolean' renders
%% as `"true"' / `"false"'. A value whose shape does not match its declared
%% type fails closed with `{invalid_cli_placeholder_value, Name, Type}' --
%% never a fall-back to Erlang term printing, so no term syntax can leak into
%% an external process's argv.
render_cli_placeholder_value(_Name, string, Value) when is_binary(Value) ->
    Value;
render_cli_placeholder_value(Name, string, Value) when is_list(Value) ->
    case unicode:characters_to_binary(Value) of
        Bin when is_binary(Bin) -> Value;
        _ -> {error, {invalid_cli_placeholder_value, Name, string}}
    end;
render_cli_placeholder_value(_Name, integer, Value) when is_integer(Value) ->
    integer_to_list(Value);
render_cli_placeholder_value(_Name, boolean, true) ->
    "true";
render_cli_placeholder_value(_Name, boolean, false) ->
    "false";
render_cli_placeholder_value(Name, Type, _Value) ->
    {error, {invalid_cli_placeholder_value, Name, Type}}.

durable_run_options(#data{run_id = RunId,
                          task_id = TaskId,
                          session_id = SessionId,
                          correlation_id = CorrelationId,
                          request_id = RequestId,
                          envelope_hash = EnvelopeHash,
                          max_output_bytes = MaxOutputBytes,
                          deadline_at_ms = DeadlineAtMs,
                          auto_resume = AutoResume,
                          run_origin = RunOrigin,
                          admission_required = AdmissionRequired,
                          admission_id = AdmissionId}) ->
    add_optional(
      run_origin, RunOrigin,
      add_optional(
        auto_resume, AutoResume,
        add_optional(
          admission_required, AdmissionRequired,
          add_optional(
            admission_id, AdmissionId,
            add_optional(
              deadline_at_ms, DeadlineAtMs,
              add_optional(
                max_output_bytes, MaxOutputBytes,
                add_optional(
                  task_id, TaskId,
                  add_optional(
                    envelope_hash, EnvelopeHash,
                    add_optional(
                      request_id, RequestId,
                      add_optional(
                        correlation_id, CorrelationId,
                        add_optional(
                          session_id, SessionId,
                          #{run_id => RunId}))))))))))).

add_optional(_Key, undefined, Acc) ->
    Acc;
add_optional(Key, Value, Acc) ->
    Acc#{Key => Value}.

%% Ownership classes are a fixed internal allowlist. New ordinary runs are
%% explicit too: boot recovery can therefore fail closed for legacy journals
%% whose absent origin cannot distinguish an old detached CLI task from a
%% generic runtime run. Unrelated atoms or arbitrary caller terms never expand
%% the journal vocabulary.
normalize_run_origin(undefined) ->
    runtime_default;
normalize_run_origin(runtime_default) ->
    runtime_default;
normalize_run_origin(cli_detached) ->
    cli_detached;
normalize_run_origin(_Origin) ->
    undefined.

%% The durable recovery decision is always a normalized boolean. Owner-managed
%% CLI work can never opt into generic boot replay, even if a bad caller passes
%% `auto_resume => true'. An unknown owner is likewise fail-closed.
normalize_auto_resume(runtime_default, undefined) -> true;
normalize_auto_resume(runtime_default, true) -> true;
normalize_auto_resume(runtime_default, false) -> false;
normalize_auto_resume(_Origin, _Value) -> false.

normalize_admission_required(cli_detached, true) -> true;
normalize_admission_required(_Origin, _Value) -> undefined.

normalize_admission_id(cli_detached, true, AdmissionId)
  when is_binary(AdmissionId), byte_size(AdmissionId) > 0 ->
    AdmissionId;
normalize_admission_id(_Origin, _Required, _AdmissionId) ->
    undefined.

ensure_admission_identity(true, AdmissionId)
  when is_binary(AdmissionId), byte_size(AdmissionId) > 0 ->
    ok;
ensure_admission_identity(true, _MissingOrInvalid) ->
    exit(invalid_admission_id);
ensure_admission_identity(_Required, _AdmissionId) ->
    ok.

claim_run_id(RunId, RunSupervisor) ->
    try soma_run_index:claim(RunId, self(), RunSupervisor) of
        Result -> Result
    catch
        exit:Reason -> {error, {run_index_unavailable, Reason}}
    end.

validate_step(Step) when not is_map(Step) ->
    {error, {invalid_step, non_map}};
validate_step(Step) ->
    case {maps:is_key(id, Step), maps:is_key(tool, Step)} of
        {false, _} ->
            {error, {invalid_step, missing_id}};
        {_, false} ->
            {error, {invalid_step, missing_tool}};
        {true, true} ->
            ok
    end.

%% A malformed step has not reached a tool-call boundary, so report a bounded
%% run-level validation failure and leave worker fields unset.
fail_invalid_step(Data, Step, Reason) ->
    Extra = add_optional(step_id, invalid_step_id(Step),
                         #{payload => #{reason => Reason}}),
    emit(Data, <<"run.failed">>, Extra),
    notify_session_failed(Data, Reason),
    {next_state, failed, Data#data{current = undefined,
                                   tool_call_id = undefined,
                                   worker_mref = undefined}}.

invalid_step_id(Step) when is_map(Step) ->
    maps:get(id, Step, undefined);
invalid_step_id(_Step) ->
    undefined.

%% Record the failure trail (`tool.failed', `step.failed', `run.failed'), tell
%% the session, and move to the `failed' state. Shared by the `{error, _}'
%% return and the worker-crash `'DOWN'' paths, which the issue collapses into
%% one terminal state.
fail_run(Data, Step, ToolCallId, WorkerPid, Reason) ->
    StepId = maps:get(id, Step),
    emit(Data, <<"tool.failed">>,
         #{step_id => StepId, tool_call_id => ToolCallId,
           tool_call_pid => WorkerPid, payload => #{reason => Reason}}),
    emit(Data, <<"step.failed">>,
         #{step_id => StepId, tool_call_id => ToolCallId,
           payload => #{reason => Reason}}),
    emit(Data, <<"run.failed">>, #{payload => #{reason => Reason}}),
    notify_session_failed(Data, Reason),
    {next_state, failed, Data#data{current = undefined,
                                   tool_call_id = undefined,
                                   worker_mref = undefined}}.

await_worker_down(MRef, WorkerPid) ->
    receive
        {'DOWN', MRef, process, WorkerPid, _Reason} ->
            ok
    after 1000 ->
        ok
    end.

%% Drop a worker monitor and flush any `'DOWN'' it already delivered, so a
%% worker's clean exit after a successful reply does not reach the crash clause.
demonitor_flush(undefined) ->
    ok;
demonitor_flush(MRef) ->
    erlang:demonitor(MRef, [flush]),
    ok.

%% Tell the session this run reached a terminal state. The session updates its
%% status view and stays alive; it learns the outcome from this message, not
%% from a link signal.
notify_session(#data{session_pid = undefined}) ->
    ok;
notify_session(#data{session_pid = Pid, run_id = RunId, outputs = Outputs}) ->
    Pid ! {run_completed, RunId, Outputs},
    ok.

%% Tell the session this run failed; the session records `failed' and stays
%% alive, learning the outcome from this message rather than a link signal.
notify_session_failed(#data{session_pid = undefined}, _Reason) ->
    ok;
notify_session_failed(#data{session_pid = Pid, run_id = RunId}, Reason) ->
    Pid ! {run_failed, RunId, Reason},
    ok.

%% Tell the session this run timed out; the session records `timeout' and stays
%% alive, learning the outcome from this message rather than a link signal.
notify_session_timeout(#data{session_pid = undefined}) ->
    ok;
notify_session_timeout(#data{session_pid = Pid, run_id = RunId}) ->
    Pid ! {run_timeout, RunId},
    ok.

%% Tell the session this run was cancelled; the session records `cancelled' and
%% stays alive, learning the outcome from this message rather than a link signal.
notify_session_cancelled(#data{session_pid = undefined}) ->
    ok;
notify_session_cancelled(#data{session_pid = Pid, run_id = RunId}) ->
    Pid ! {run_cancelled, RunId},
    ok.

emit(#data{event_store = undefined}, _Type, _Extra) ->
    ok;
emit(Data, Type, Extra) ->
    Base0 = #{session_id => Data#data.session_id,
              run_id => Data#data.run_id,
              event_type => Type},
    %% Stamp the run's `correlation_id' on every event it emits -- but only when
    %% the run actually holds one. A run started without a correlation id emits
    %% exactly the trail it emits today; the key is never merged as
    %% `undefined', so `by_correlation/2' matches only events that carry a real
    %% id.
    Base = case Data#data.correlation_id of
               undefined -> Base0;
               CorrId -> Base0#{correlation_id => CorrId}
           end,
    soma_event_store:append(Data#data.event_store, maps:merge(Base, Extra)),
    ok.

%% Resolve a step's args against prior step outputs. A bare `from_step' key
%% means the whole input is the referenced step's recorded output. Otherwise any
%% `{from_step, Id}' value is replaced by that step's recorded output.
resolve_args(#{from_step := PriorId}, Outputs) ->
    maps:get(PriorId, Outputs);
resolve_args(Args, Outputs) when is_map(Args) ->
    maps:map(fun(_K, {from_step, PriorId}) -> maps:get(PriorId, Outputs);
                (_K, V) -> V
             end, Args).

%% Split resolved args into the tool's input and ctx additions. The sandbox
%% `root' the file tools read from ctx travels in the step args, so lift it out
%% of the input and into the ctx.
split_ctx_args(Args) when is_map(Args) ->
    case maps:take(root, Args) of
        {Root, Rest} -> {Rest, #{root => Root}};
        error -> {Args, #{}}
    end;
split_ctx_args(Args) ->
    {Args, #{}}.

new_tool_call_id() ->
    list_to_binary("tc-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).
