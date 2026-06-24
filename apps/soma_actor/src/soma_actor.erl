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
               runs = #{}, waiters = #{}}).

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
            {keep_state, Data2, [{reply, From, {ok, TaskId}}]};
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
            %% Defer the reply: park From against the task and answer when the
            %% run completes. The caller stays blocked inside its gen_statem:call.
            Waiters = maps:put(TaskId, From, Data2#data.waiters),
            {keep_state, Data2#data{waiters = Waiters}};
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
            case maps:get(run_pid, Task, undefined) of
                RunPid when is_pid(RunPid) ->
                    RunPid ! cancel,
                    {keep_state, Data, [{reply, From, ok}]};
                _ ->
                    {keep_state, Data, [{reply, From, {error, not_running}}]}
            end
    end;
idle(info, {run_completed, RunId, Outputs}, Data) ->
    case maps:get(RunId, Data#data.runs, undefined) of
        undefined ->
            {keep_state, Data};
        TaskId ->
            Task = maps:get(TaskId, Data#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => completed, result => Outputs},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
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
            Task = maps:get(TaskId, Data#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => failed, reason => Reason},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
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
            Task = maps:get(TaskId, Data#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => failed, reason => timeout},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
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
            Task = maps:get(TaskId, Data#data.tasks),
            CorrelationId = maps:get(correlation_id, Task),
            Task1 = Task#{status => cancelled},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data1 = Data#data{tasks = Tasks},
            emit(Data1, <<"actor.task.cancelled">>,
                 #{task_id => TaskId, correlation_id => CorrelationId}),
            reply_waiter(TaskId, {error, cancelled}, Data1)
    end;
idle(_EventType, _Event, Data) ->
    {keep_state, Data}.

validate_envelope(Envelope) when is_map(Envelope) ->
    case maps:is_key(type, Envelope) andalso maps:is_key(payload, Envelope) of
        true -> ok;
        false -> {error, missing_required_field}
    end;
validate_envelope(_Envelope) ->
    {error, not_a_map}.

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
            Runs = maps:put(RunId, TaskId, Data#data.runs),
            Task = maps:get(TaskId, Data#data.tasks),
            Task1 = Task#{status => running, run_id => RunId,
                          run_pid => RunPid},
            Tasks = maps:put(TaskId, Task1, Data#data.tasks),
            Data#data{runs = Runs, tasks = Tasks};
        _ ->
            Data
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

emit(#data{event_store = undefined}, _Type, _Extra) ->
    ok;
emit(Data, Type, Extra) ->
    Base = #{actor_id => Data#data.actor_id,
             event_type => Type},
    Event = maps:merge(Base, Extra),
    soma_event_store:append(Data#data.event_store, Event),
    ok.
