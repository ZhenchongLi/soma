%% @doc Serialized production ingress for delegated tasks. One bounded request
%% identity is admitted once and routed to one temporary coordinator.
-module(soma_delegate).

-behaviour(gen_server).

-define(MAX_ID_BYTES, 256).
-define(MAX_TASK_SPEC_BYTES, 65536).

-export([start_link/0, submit/1, status/1, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

submit(TaskSpec) ->
    gen_server:call(?MODULE, {submit, TaskSpec}).

status(TaskId) ->
    gen_server:call(?MODULE, {status, TaskId}).

cancel(TaskId) ->
    gen_server:call(?MODULE, {cancel, TaskId}).

init([]) ->
    {ok, #{requests => #{}, tasks => #{}, monitors => #{}}}.

handle_call({submit, TaskSpec}, _From, State) ->
    case request_id(TaskSpec) of
        {ok, RequestId} ->
            submit_request(RequestId, TaskSpec, State);
        {error, _Reason} = Error ->
            {reply, Error, State}
    end;
handle_call({status, TaskId}, _From, State) ->
    status_task(TaskId, State);
handle_call({cancel, TaskId}, From, State) ->
    cancel_task(TaskId, From, State);
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, CoordinatorPid, _Reason}, State) ->
    {noreply, remove_active_coordinator(MRef, CoordinatorPid, State)};
handle_info({delegate_terminal, TaskId, CoordinatorPid, Projection}, State) ->
    {noreply,
     store_terminal_projection(
       TaskId, CoordinatorPid, Projection, State)};
handle_info(_Info, State) ->
    {noreply, State}.

status_task(TaskId, State = #{tasks := Tasks}) ->
    case maps:get(TaskId, Tasks, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Route = #{terminal_projection := Projection}
          when is_map(Projection) ->
            {reply, {ok, public_projection(Route, Projection)}, State};
        #{coordinator_pid := CoordinatorPid} when is_pid(CoordinatorPid) ->
            {reply, soma_delegate_coordinator:status(CoordinatorPid), State}
    end.

cancel_task(TaskId, From, State = #{tasks := Tasks}) ->
    case maps:get(TaskId, Tasks, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Route = #{terminal_projection := #{status := cancelled} = Projection} ->
            {reply, {ok, public_projection(Route, Projection)}, State};
        #{terminal_projection := Projection} when is_map(Projection) ->
            {reply, {error, not_running}, State};
        Route = #{coordinator_pid := CoordinatorPid}
          when is_pid(CoordinatorPid) ->
            Waiters = maps:get(cancel_waiters, Route, []),
            UpdatedRoute = Route#{cancel_waiters => [From | Waiters]},
            case Waiters of
                [] ->
                    soma_delegate_coordinator:cancel(
                      CoordinatorPid, TaskId);
                _AlreadyCancelling ->
                    ok
            end,
            {noreply,
             State#{tasks := maps:put(TaskId, UpdatedRoute, Tasks)}}
    end.

submit_request(RequestId, TaskSpec,
               State = #{requests := Requests, tasks := Tasks}) ->
    case maps:find(RequestId, Requests) of
        {ok, TaskId} ->
            Route = maps:get(TaskId, Tasks),
            {reply, {ok, maps:get(accepted_handle, Route)}, State};
        error ->
            start_new_request(RequestId, TaskSpec, State)
    end.

start_new_request(RequestId, TaskSpec, State) ->
    case validate_new_task(TaskSpec) of
        {ok, CorrelationId0} ->
            TaskId = mint_task_id(),
            CorrelationId = resolve_correlation_id(CorrelationId0, TaskId),
            Handle = #{status => accepted,
                       request_id => RequestId,
                       task_id => TaskId,
                       correlation_id => CorrelationId},
            CoordinatorOpts = TaskSpec#{request_id => RequestId,
                                        task_id => TaskId,
                                        correlation_id => CorrelationId,
                                        ingress_pid => self()},
            start_coordinator(CoordinatorOpts, Handle, State);
        {error, _Reason} = Error ->
            {reply, Error, State}
    end.

start_coordinator(CoordinatorOpts,
                  Handle = #{request_id := RequestId, task_id := TaskId},
                  State = #{requests := Requests,
                            tasks := Tasks,
                            monitors := Monitors}) ->
    case soma_delegate_coordinator_sup:start_coordinator(CoordinatorOpts) of
        {ok, CoordinatorPid} ->
            MRef = erlang:monitor(process, CoordinatorPid),
            Route = #{request_id => RequestId,
                      task_id => TaskId,
                      accepted_handle => Handle,
                      coordinator_pid => CoordinatorPid,
                      coordinator_mref => MRef,
                      terminal_projection => undefined},
            AdmittedState = State#{
                requests := maps:put(RequestId, TaskId, Requests),
                tasks := maps:put(TaskId, Route, Tasks),
                monitors := maps:put(MRef, TaskId, Monitors)},
            CoordinatorPid ! {delegate_begin, TaskId},
            {reply, {ok, Handle}, AdmittedState};
        {error, _Reason} ->
            {reply, {error, coordinator_start_failed}, State}
    end.

remove_active_coordinator(MRef, CoordinatorPid,
                          State = #{tasks := Tasks,
                                    monitors := Monitors}) ->
    case maps:take(MRef, Monitors) of
        {TaskId, RemainingMonitors} ->
            Route = maps:get(TaskId, Tasks),
            UpdatedRoute =
                case maps:get(coordinator_pid, Route, undefined) of
                    CoordinatorPid ->
                        Projection = coordinator_crashed_projection(),
                        reply_cancel_waiters(Route,
                                             public_projection(
                                               Route, Projection)),
                        terminal_route(Route, Projection);
                    _OtherPid ->
                        Route
                end,
            State#{tasks := maps:put(TaskId, UpdatedRoute, Tasks),
                   monitors := RemainingMonitors};
        error ->
            State
    end.

store_terminal_projection(
  TaskId, CoordinatorPid, Projection,
  State = #{tasks := Tasks, monitors := Monitors})
  when is_map(Projection) ->
    case maps:get(TaskId, Tasks, undefined) of
        Route = #{coordinator_pid := CoordinatorPid,
                  coordinator_mref := MRef,
                  terminal_projection := undefined} ->
            _ = erlang:demonitor(MRef, [flush]),
            PublicProjection = public_projection(Route, Projection),
            reply_cancel_waiters(Route, PublicProjection),
            TerminalRoute = terminal_route(Route, Projection),
            State#{tasks := maps:put(TaskId, TerminalRoute, Tasks),
                   monitors := maps:remove(MRef, Monitors)};
        _StaleOrMismatchedCoordinator ->
            State
    end;
store_terminal_projection(_TaskId, _CoordinatorPid, _Projection, State) ->
    State.

reply_cancel_waiters(Route, Projection) ->
    lists:foreach(
      fun(From) -> gen_server:reply(From, {ok, Projection}) end,
      maps:get(cancel_waiters, Route, [])).

public_projection(Route, Projection) ->
    maps:merge(maps:get(accepted_handle, Route), Projection).

terminal_route(Route, Projection) ->
    #{request_id => maps:get(request_id, Route),
      task_id => maps:get(task_id, Route),
      accepted_handle => maps:get(accepted_handle, Route),
      terminal_projection => Projection}.

request_id(#{request_id := RequestId}) ->
    validate_id(RequestId, invalid_request_id);
request_id(_TaskSpec) ->
    {error, invalid_request_id}.

validate_new_task(TaskSpec) when is_map(TaskSpec) ->
    case byte_size(term_to_binary(TaskSpec, [deterministic])) =<
             ?MAX_TASK_SPEC_BYTES of
        true ->
            validate_optional_correlation_id(
              maps:get(correlation_id, TaskSpec, default));
        false ->
            {error, task_spec_too_large}
    end.

validate_optional_correlation_id(default) ->
    {ok, default};
validate_optional_correlation_id(CorrelationId) ->
    validate_id(CorrelationId, invalid_correlation_id).

validate_id(Id, _Error) when is_binary(Id),
                             byte_size(Id) > 0,
                             byte_size(Id) =< ?MAX_ID_BYTES ->
    {ok, Id};
validate_id(_Id, Error) ->
    {error, Error}.

resolve_correlation_id(default, TaskId) ->
    TaskId;
resolve_correlation_id(CorrelationId, _TaskId) ->
    CorrelationId.

mint_task_id() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<"delegate-task-", Suffix/binary>>.

coordinator_crashed_projection() ->
    #{status => failed, reason => coordinator_crashed}.
