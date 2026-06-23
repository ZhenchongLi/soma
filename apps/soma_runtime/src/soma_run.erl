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
-export([executing/3, waiting_tool/3, completed/3]).

-record(data, {run_id,
               session_id,
               event_store,
               steps = [],
               pending = [],
               outputs = #{},
               current,
               tool_call_id}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

callback_mode() ->
    state_functions.

init(Opts) ->
    Data = #data{run_id = maps:get(run_id, Opts),
                 session_id = maps:get(session_id, Opts, undefined),
                 event_store = maps:get(event_store, Opts, undefined),
                 steps = maps:get(steps, Opts, []),
                 pending = maps:get(steps, Opts, [])},
    emit(Data, <<"run.started">>, #{}),
    {ok, executing, Data, [{next_event, internal, next_step}]}.

%% Drive the next step, or finish the run when none remain.
executing(internal, next_step, Data = #data{pending = []}) ->
    emit(Data, <<"run.completed">>, #{}),
    {next_state, completed, Data};
executing(internal, next_step, Data = #data{pending = [Step | _Rest]}) ->
    StepId = maps:get(id, Step),
    ToolName = maps:get(tool, Step),
    Args = maps:get(args, Step, #{}),
    ToolCallId = new_tool_call_id(),
    emit(Data, <<"step.started">>,
         #{step_id => StepId, tool_call_id => ToolCallId}),
    emit(Data, <<"tool.started">>,
         #{step_id => StepId, tool_call_id => ToolCallId}),
    {ok, Module} = soma_tool_registry:resolve(ToolName),
    Ctx = #{session_id => Data#data.session_id,
            run_id => Data#data.run_id,
            step_id => StepId,
            tool_call_id => ToolCallId},
    {ok, _WorkerPid} = soma_tool_call:start(#{module => Module,
                                              input => Args,
                                              ctx => Ctx,
                                              tool_call_id => ToolCallId,
                                              reply_to => self()}),
    {next_state, waiting_tool,
     Data#data{current = Step, tool_call_id = ToolCallId}}.

%% Wait for the active tool-call worker's result; only then advance.
waiting_tool(info, {tool_result, ToolCallId, WorkerPid, {ok, Output}},
             Data = #data{tool_call_id = ToolCallId,
                          current = Step,
                          pending = [Step | Rest],
                          outputs = Outputs}) ->
    StepId = maps:get(id, Step),
    emit(Data, <<"tool.succeeded">>,
         #{step_id => StepId, tool_call_id => ToolCallId,
           tool_call_pid => WorkerPid}),
    emit(Data, <<"step.succeeded">>,
         #{step_id => StepId, tool_call_id => ToolCallId}),
    NewData = Data#data{pending = Rest,
                        outputs = Outputs#{StepId => Output},
                        current = undefined,
                        tool_call_id = undefined},
    {next_state, executing, NewData, [{next_event, internal, next_step}]}.

completed(_EventType, _Event, Data) ->
    {keep_state, Data}.

%%% Internal

emit(#data{event_store = undefined}, _Type, _Extra) ->
    ok;
emit(Data, Type, Extra) ->
    Base = #{session_id => Data#data.session_id,
             run_id => Data#data.run_id,
             event_type => Type},
    soma_event_store:append(Data#data.event_store, maps:merge(Base, Extra)),
    ok.

new_tool_call_id() ->
    list_to_binary("tc-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).
