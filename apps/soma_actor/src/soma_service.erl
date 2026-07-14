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
    {ok, #state{event_store = runtime_event_store(), policy = Policy}}.

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
                 State = #state{policy = Policy}) ->
    Steps = operation_steps(maps:get(operation, Envelope)),
    Proposal = #{kind => run_steps, steps => Steps},
    case soma_policy:check(Proposal, Policy) of
        allow ->
            start_allowed_invocation(
              Envelope, EnvelopeHash, Steps, State);
        {reject, Reason} ->
            {reply, {error, {policy_rejected, Reason}}, State}
    end.

start_allowed_invocation(Envelope, EnvelopeHash, Steps,
                         State = #state{event_store = EventStore,
                                        tasks = Tasks,
                                        requests = Requests,
                                        runs = Runs,
                                        monitors = Monitors}) ->
    TaskId = mint_id("service-task-"),
    RunId = mint_id("service-run-"),
    RequestId = maps:get(request_id, Envelope),
    RunOpts0 = #{run_id => RunId,
                 session_pid => self(),
                 event_store => EventStore,
                 steps => Steps},
    RunOpts = maybe_add_correlation(Envelope, RunOpts0),
    case soma_run_sup:start_run(RunOpts) of
        {ok, RunPid} ->
            MRef = erlang:monitor(process, RunPid),
            Handle = #{task_id => TaskId,
                       request_id => RequestId,
                       status => accepted},
            Task0 = #{task_id => TaskId,
                      request_id => RequestId,
                      status => running,
                      run_id => RunId,
                      run_pid => RunPid,
                      run_mref => MRef},
            Task = maybe_add_max_output_bytes(Envelope, Task0),
            Request = #{envelope_hash => EnvelopeHash,
                        task_id => TaskId,
                        accepted_handle => Handle},
            NewState =
                State#state{
                  tasks = maps:put(TaskId, Task, Tasks),
                  requests = maps:put(RequestId, Request, Requests),
                  runs = maps:put(RunId, TaskId, Runs),
                  monitors = maps:put(
                               MRef,
                               #{run_id => RunId, run_pid => RunPid},
                               Monitors)},
            {reply, {ok, Handle}, NewState};
        {error, Reason} ->
            {reply, {error, {run_start_failed, Reason}}, State}
    end.

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
                          monitors = Monitors}) ->
    case maps:take(RunId, Runs) of
        error ->
            State;
        {TaskId, NewRuns} ->
            Task = maps:get(TaskId, Tasks),
            RunPid = maps:get(run_pid, Task),
            MRef = maps:get(run_mref, Task),
            erlang:demonitor(MRef, [flush]),
            terminate_run_child(RunPid),
            Task1 = maps:merge(
                      maps:without([run_pid, run_mref], Task),
                      terminal_for_task(Terminal, Task)),
            State#state{
              tasks = maps:put(TaskId, Task1, Tasks),
              runs = NewRuns,
              monitors = maps:remove(MRef, Monitors)}
    end.

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

terminate_run_child(RunPid) ->
    _ = supervisor:terminate_child(soma_run_sup, RunPid),
    ok.

public_task(Task) ->
    maps:with([task_id, request_id, status, result, reason], Task).

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
