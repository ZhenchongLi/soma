%% @doc The `soma_runtime' application callback. Starting the application boots
%% the supervision tree via `soma_sup'.
-module(soma_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    soma_sup:start_link().

stop(_State) ->
    ok.
