%% @doc Serialized production ingress for delegated tasks. One bounded request
%% identity is admitted once and routed to one temporary coordinator.
-module(soma_delegate).

-behaviour(gen_server).

-define(MAX_ID_BYTES, 256).
-define(MAX_TASK_SPEC_BYTES, 65536).

-export([start_link/0, submit/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

submit(TaskSpec) ->
    gen_server:call(?MODULE, {submit, TaskSpec}).

init([]) ->
    {ok, #{requests => #{}, tasks => #{}, monitors => #{}}}.

handle_call({submit, TaskSpec}, _From, State) ->
    case request_id(TaskSpec) of
        {ok, RequestId} ->
            submit_request(RequestId, TaskSpec, State);
        {error, _Reason} = Error ->
            {reply, Error, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, CoordinatorPid, _Reason}, State) ->
    {noreply, remove_active_coordinator(MRef, CoordinatorPid, State)};
handle_info(_Info, State) ->
    {noreply, State}.

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
                                        correlation_id => CorrelationId},
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
                      coordinator_mref => MRef},
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
                        Route#{coordinator_pid := undefined,
                               coordinator_mref := undefined};
                    _OtherPid ->
                        Route
                end,
            State#{tasks := maps:put(TaskId, UpdatedRoute, Tasks),
                   monitors := RemainingMonitors};
        error ->
            State
    end.

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
