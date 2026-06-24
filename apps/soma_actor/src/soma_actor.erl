%% @doc A single actor instance, as a `gen_statem'. This slice gives it the
%% `gen_statem' shape only: it implements the behaviour and exports
%% `start_link/1', `callback_mode/0', and `init/1'. Later slices add the
%% `idle' state, config in the data record, and `actor.started' emission.
-module(soma_actor).

-behaviour(gen_statem).

-export([start_link/1]).
-export([callback_mode/0, init/1]).
-export([idle/3]).

-record(data, {}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

callback_mode() ->
    state_functions.

init(_Opts) ->
    {ok, idle, #data{}}.

idle(_EventType, _Event, Data) ->
    {keep_state, Data}.
