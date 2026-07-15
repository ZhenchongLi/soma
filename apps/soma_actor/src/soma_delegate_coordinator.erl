%% @doc One temporary delegated-task owner. It starts inert so the ingress can
%% install its request route and monitor before allowing task work to begin.
-module(soma_delegate_coordinator).

-behaviour(gen_statem).

-export([start_link/1]).
-export([init/1, callback_mode/0, handle_event/4]).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

init(Opts = #{request_id := RequestId,
              task_id := TaskId,
              correlation_id := CorrelationId})
  when is_binary(RequestId), is_binary(TaskId), is_binary(CorrelationId) ->
    Data = #{request_id => RequestId,
             task_id => TaskId,
             correlation_id => CorrelationId,
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
handle_event(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.

initial_checkpoint(Opts) ->
    maps:get(context_checkpoint, Opts, maps:get(checkpoint, Opts, #{})).
