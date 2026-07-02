%% @doc The `soma_actor' application callback. `start/2' boots the root
%% supervisor `soma_actor_sup'.
-module(soma_actor_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case soma_actor_sup:start_link() of
        {ok, SupPid} ->
            case soma_tool_registry:register_tool(soma_tool_ask_actor:manifest()) of
                ok ->
                    {ok, SupPid};
                {error, Reason} ->
                    exit(SupPid, shutdown),
                    {error, {ask_actor_tool_registration_failed, Reason}}
            end;
        Error ->
            Error
    end.

stop(_State) ->
    ok.
