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
               correlation_id,
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

callback_mode() ->
    state_functions.

init(Opts) ->
    Data = #data{run_id = maps:get(run_id, Opts),
                 session_id = maps:get(session_id, Opts, undefined),
                 session_pid = maps:get(session_pid, Opts, undefined),
                 correlation_id = maps:get(correlation_id, Opts, undefined),
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
    case maps:is_key(pending, Opts) of
        true ->
            FirstPendingStep = first_pending_step(Data#data.pending),
            emit(Data, <<"run.resumed">>,
                 #{step_id => FirstPendingStep,
                   payload => #{first_pending_step => FirstPendingStep}});
        false ->
            emit(Data, <<"run.started">>,
                 #{payload => #{steps => Data#data.steps,
                                run_options => durable_run_options(Data)}})
    end,
    {ok, executing, Data, [{next_event, internal, next_step}]}.

%% The step id of the first not-yet-committed step, or `undefined' when the
%% pending suffix is empty (a resume with nothing left to run).
first_pending_step([Step | _]) ->
    maps:get(id, Step);
first_pending_step([]) ->
    undefined.

%% Drive the next step, or finish the run when none remain.
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
            end
    end.

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
           tool_call_pid => WorkerPid}),
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
                        current = undefined,
                        tool_call_id = undefined,
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
    kill_os_process(OsPid),
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
    kill_os_process(OsPid),
    emit(Data, <<"run.cancelled">>,
         #{step_id => maps:get(id, Step), tool_call_id => ToolCallId}),
    notify_session_cancelled(Data),
    {next_state, cancelled, Data#data{current = undefined,
                                      tool_call_id = undefined,
                                      worker_pid = undefined,
                                      worker_mref = undefined,
                                      os_pid = undefined}}.

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
cli_argv_placeholder_name(Arg) when is_list(Arg) ->
    case unicode:characters_to_binary(Arg) of
        Bin when is_binary(Bin) -> cli_argv_placeholder_name(Bin);
        _ -> none
    end;
cli_argv_placeholder_name(_) ->
    none.

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
                          session_id = SessionId,
                          correlation_id = CorrelationId}) ->
    add_optional(correlation_id, CorrelationId,
                 add_optional(session_id, SessionId, #{run_id => RunId})).

add_optional(_Key, undefined, Acc) ->
    Acc;
add_optional(Key, Value, Acc) ->
    Acc#{Key => Value}.

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

%% Kill the external OS process a `cli' step launched, if one was reported.
%% `exit(WorkerPid, kill)' removes only the BEAM worker; the OS child the worker's
%% port spawned can outlive it as an orphan, so the run signals it directly. The
%% OS pid is a BEAM-produced integer, never user text, so there is no shell
%% interpolation surface. An `erlang_module' step reports no OS pid, so this is a
%% no-op for the in-BEAM teardown.
kill_os_process(undefined) ->
    ok;
kill_os_process(OsPid) when is_integer(OsPid) ->
    case os:find_executable("kill") of
        false ->
            ok;
        Kill ->
            Port = open_port(
                     {spawn_executable, Kill},
                     [{args, ["-KILL", integer_to_list(OsPid)]},
                      exit_status, binary, use_stdio, stderr_to_stdout]),
            wait_kill_done(Port),
            ok
    end.

%% Drain the kill port to completion so its `exit_status' message never leaks
%% into the run's gen_statem mailbox. `kill -KILL' is near-instant; a short bound
%% guards against a stuck child, after which the port is force-closed.
wait_kill_done(Port) ->
    receive
        {Port, {exit_status, _}} ->
            ok;
        {Port, {data, _}} ->
            wait_kill_done(Port)
    after 1000 ->
        try erlang:port_close(Port) catch _:_ -> ok end,
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
