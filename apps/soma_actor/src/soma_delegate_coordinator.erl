%% @doc One temporary delegated-task owner. It starts inert so the ingress can
%% install its request route and monitor before allowing task work to begin.
-module(soma_delegate_coordinator).

-behaviour(gen_statem).

-export([start_link/1, status/1, cancel/2]).
-export([init/1, callback_mode/0, handle_event/4]).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

status(CoordinatorPid) when is_pid(CoordinatorPid) ->
    gen_statem:call(CoordinatorPid, status).

cancel(CoordinatorPid, TaskId) when is_pid(CoordinatorPid) ->
    gen_statem:cast(CoordinatorPid, {cancel, TaskId}).

init(Opts = #{request_id := RequestId,
              task_id := TaskId,
              correlation_id := CorrelationId,
              ingress_pid := IngressPid})
  when is_binary(RequestId), is_binary(TaskId), is_binary(CorrelationId),
       is_pid(IngressPid) ->
    Data = #{request_id => RequestId,
             task_id => TaskId,
             correlation_id => CorrelationId,
             ingress_pid => IngressPid,
             status => accepted,
             objective => maps:get(objective, Opts, undefined),
             output_contract => maps:get(output_contract, Opts, undefined),
             context_checkpoint => initial_checkpoint(Opts),
             budgets => maps:get(budgets, Opts, #{}),
             usage => #{},
             mutation_ledger => [],
             unknown_outcome_ledger => [],
             scoped_leases =>
                 #{requests => maps:get(lease_requests, Opts, []),
                   handles => #{},
                   guard => undefined},
             next_round_id => 1,
             active_round => undefined,
             terminal_result => undefined,
             round_sequence => maps:get(round_sequence, Opts, [])},
    {ok, awaiting_start, Data}.

callback_mode() ->
    handle_event_function.

handle_event(info, {delegate_begin, TaskId}, awaiting_start,
             Data = #{task_id := TaskId}) ->
    {next_state, running, Data#{status := running}};
handle_event({call, From}, status, _StateName, Data) ->
    {keep_state, Data,
     [{reply, From, {ok, public_projection(Data)}}]};
handle_event(cast, {cancel, TaskId}, StateName,
             Data = #{task_id := TaskId})
  when StateName =:= awaiting_start; StateName =:= running ->
    Projection = #{status => cancelled},
    {next_state, cleaning,
     Data#{status := cancelled, terminal_result := Projection},
     [{next_event, internal, finish_cleanup}]};
handle_event(internal, finish_cleanup, cleaning,
             Data = #{ingress_pid := IngressPid,
                      task_id := TaskId,
                      terminal_result := Projection}) ->
    IngressPid ! {delegate_terminal, TaskId, self(), Projection},
    {stop, normal, Data};
handle_event(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.

initial_checkpoint(Opts) ->
    maps:get(context_checkpoint, Opts, maps:get(checkpoint, Opts, #{})).

public_projection(Data) ->
    maps:with([request_id, task_id, correlation_id, status], Data).
