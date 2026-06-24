%% @doc The `soma_actor' application callback. Booting the supervision tree is
%% wired in a later slice; this scaffolding only provides the `mod' callback the
%% application resource declares.
-module(soma_actor_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {error, not_implemented}.

stop(_State) ->
    ok.
