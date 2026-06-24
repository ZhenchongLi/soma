%% @doc A single actor instance, as a `gen_statem'. This slice gives it the
%% `gen_statem' shape only: it implements the behaviour and exports
%% `start_link/1', `callback_mode/0', and `init/1'. Later slices add the
%% `idle' state, config in the data record, and `actor.started' emission.
-module(soma_actor).

-behaviour(gen_statem).

-export([start_link/1]).
-export([send/2]).
-export([callback_mode/0, init/1]).
-export([idle/3]).

-record(data, {actor_id, model_config, tool_policy, event_store}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% @doc Synchronous entry point. Hands the envelope to the actor process and
%% returns `{ok, TaskId}' once the task is accepted, or `{error, Reason}' if the
%% envelope is invalid. The work runs inside the actor via `idle/3', so the
%% actor is never bypassed.
send(ActorRef, Envelope) ->
    gen_statem:call(ActorRef, {send, Envelope}).

callback_mode() ->
    state_functions.

init(Opts) ->
    Data = #data{actor_id = maps:get(actor_id, Opts, undefined),
                 model_config = maps:get(model_config, Opts, undefined),
                 tool_policy = maps:get(tool_policy, Opts, undefined),
                 event_store = maps:get(event_store, Opts, undefined)},
    emit(Data, <<"actor.started">>),
    {ok, idle, Data}.

idle({call, From}, {send, Envelope}, Data) ->
    case validate_envelope(Envelope) of
        ok ->
            TaskId = resolve_task_id(Envelope),
            {keep_state, Data, [{reply, From, {ok, TaskId}}]};
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]}
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

mint_task_id() ->
    list_to_binary(
      "task-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

emit(#data{event_store = undefined}, _Type) ->
    ok;
emit(Data, Type) ->
    Event = #{actor_id => Data#data.actor_id,
              event_type => Type},
    soma_event_store:append(Data#data.event_store, Event),
    ok.
