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
    {ok, awaiting_start, Opts#{status => accepted}}.

callback_mode() ->
    handle_event_function.

handle_event(info, {delegate_begin, TaskId}, awaiting_start,
             Data = #{task_id := TaskId}) ->
    {next_state, running, Data#{status := running}};
handle_event(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.
