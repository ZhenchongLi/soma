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

-export([start_link/1]).
-export([callback_mode/0, init/1]).
-export([executing/3, waiting_tool/3, completed/3, failed/3, timeout/3,
         cancelled/3]).

-record(data, {run_id,
               session_id,
               session_pid,
               event_store,
               steps = [],
               pending = [],
               outputs = #{},
               current,
               tool_call_id,
               worker_pid,
               worker_mref}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

callback_mode() ->
    state_functions.

init(Opts) ->
    Data = #data{run_id = maps:get(run_id, Opts),
                 session_id = maps:get(session_id, Opts, undefined),
                 session_pid = maps:get(session_pid, Opts, undefined),
                 event_store = maps:get(event_store, Opts, undefined),
                 steps = maps:get(steps, Opts, []),
                 pending = maps:get(steps, Opts, [])},
    emit(Data, <<"run.started">>, #{}),
    {ok, executing, Data, [{next_event, internal, next_step}]}.

%% Drive the next step, or finish the run when none remain.
executing(internal, next_step, Data = #data{pending = []}) ->
    emit(Data, <<"run.completed">>, #{}),
    notify_session(Data),
    {next_state, completed, Data};
executing(internal, next_step, Data = #data{pending = [Step | _Rest]}) ->
    StepId = maps:get(id, Step),
    ToolName = maps:get(tool, Step),
    Resolved = resolve_args(maps:get(args, Step, #{}), Data#data.outputs),
    {Input, CtxExtra} = split_ctx_args(Resolved),
    ToolCallId = new_tool_call_id(),
    emit(Data, <<"step.started">>,
         #{step_id => StepId, tool_call_id => ToolCallId}),
    {ok, Module} = soma_tool_registry:resolve(ToolName),
    Ctx = maps:merge(CtxExtra,
                     #{session_id => Data#data.session_id,
                       run_id => Data#data.run_id,
                       step_id => StepId,
                       tool_call_id => ToolCallId}),
    {ok, WorkerPid} = soma_tool_call:start(#{module => Module,
                                             input => Input,
                                             ctx => Ctx,
                                             tool_call_id => ToolCallId,
                                             reply_to => self()}),
    %% Record `tool.started' after the worker is spawned so the event carries the
    %% worker pid: the run can prove each invocation ran in its own process, and
    %% the timeout/cancel paths give a test the pid to confirm the worker died.
    emit(Data, <<"tool.started">>,
         #{step_id => StepId, tool_call_id => ToolCallId,
           tool_call_pid => WorkerPid}),
    %% Monitor the worker so a crash (the tool raises, the worker dies without
    %% replying) reaches the run as a `'DOWN'' message rather than hanging the
    %% wait forever.
    MRef = erlang:monitor(process, WorkerPid),
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
                        current = undefined,
                        tool_call_id = undefined,
                        worker_mref = undefined},
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
             Data = #data{worker_pid = WorkerPid, worker_mref = MRef}) ->
    demonitor_flush(MRef),
    exit(WorkerPid, kill),
    emit(Data, <<"run.timeout">>, #{}),
    notify_session_timeout(Data),
    {next_state, timeout, Data#data{current = undefined,
                                    tool_call_id = undefined,
                                    worker_pid = undefined,
                                    worker_mref = undefined}};
%% The run was cancelled: the session forwarded a `cancel' while the run waited
%% on its active worker. Kill that worker, record `run.cancelled', tell the
%% session, and move to the `cancelled' state. The brutal kill makes
%% cancellation real rather than a flag checked at the end.
waiting_tool(info, cancel,
             Data = #data{worker_pid = WorkerPid, worker_mref = MRef}) ->
    demonitor_flush(MRef),
    exit(WorkerPid, kill),
    emit(Data, <<"run.cancelled">>, #{}),
    notify_session_cancelled(Data),
    {next_state, cancelled, Data#data{current = undefined,
                                      tool_call_id = undefined,
                                      worker_pid = undefined,
                                      worker_mref = undefined}}.

completed(_EventType, _Event, Data) ->
    {keep_state, Data}.

failed(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% Terminal `timeout' state: the run stays alive holding its final state, like
%% `completed/3'. A stray `'DOWN'' from the worker the timeout killed is just
%% noise here and is ignored.
timeout(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% Terminal `cancelled' state: the run stays alive holding its final state, like
%% `completed/3'. A stray `'DOWN'' from the worker the cancel killed is just
%% noise here and is ignored.
cancelled(_EventType, _Event, Data) ->
    {keep_state, Data}.

%%% Internal

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
    Base = #{session_id => Data#data.session_id,
             run_id => Data#data.run_id,
             event_type => Type},
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
