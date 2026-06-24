%% @doc The `soma_actor' application callback. `start/2' boots the root
%% supervisor `soma_actor_sup'.
-module(soma_actor_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    soma_actor_sup:start_link().

stop(_State) ->
    ok.
