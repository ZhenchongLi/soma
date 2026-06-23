%% @doc One execution attempt for a run, as a `gen_statem'. v0.1 happy path so
%% far: a run starts under `soma_run_sup', owns its `run_id', and stays alive in
%% an initial state. Sequential step execution arrives in a later criterion.
-module(soma_run).

-behaviour(gen_statem).

-export([start_link/1]).
-export([callback_mode/0, init/1, ready/3]).

-record(data, {run_id, steps}).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

callback_mode() ->
    state_functions.

init(Opts) ->
    Data = #data{run_id = maps:get(run_id, Opts),
                 steps = maps:get(steps, Opts, [])},
    {ok, ready, Data}.

ready(_EventType, _Event, Data) ->
    {keep_state, Data}.
