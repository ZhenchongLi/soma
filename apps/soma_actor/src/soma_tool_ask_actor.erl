%% @doc Actor-owned ask_actor tool manifest.
-module(soma_tool_ask_actor).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => ask_actor,
      effect => state,
      idempotent => false,
      timeout_ms => 60000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module,
                  module => ?MODULE,
                  description =>
                      <<"Ask a named Soma actor and return its task result.">>}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {error, soma_tool:error()}.
invoke(_Input, _Ctx) ->
    {error, ask_actor_not_implemented}.
