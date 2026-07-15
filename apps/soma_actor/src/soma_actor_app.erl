%% @doc The `soma_actor' application callback. `start/2' boots the root
%% supervisor `soma_actor_sup'.
-module(soma_actor_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Actor-owned descriptors must exist before the supervisor starts:
    %% soma_service replays durable runs from its init, and a recovered
    %% pending ask_actor step would otherwise fail {unregistered_tool, _}
    %% in the registration gap. The registry is available here because
    %% soma_runtime is a dependency application.
    case soma_tool_registry:register_tool(soma_tool_ask_actor:manifest()) of
        ok ->
            soma_actor_sup:start_link();
        {error, Reason} ->
            {error, {ask_actor_tool_registration_failed, Reason}}
    end.

stop(_State) ->
    ok.
