%% @doc Test-only non-idempotent state tool that stays in flight until its
%% owning runtime is interrupted.
-module(soma_service_hanging_state_tool).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => service_hanging_state,
      effect => state,
      idempotent => false,
      timeout_ms => 60000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module, module => ?MODULE}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()}.
invoke(Input, _Ctx) ->
    timer:sleep(60000),
    {ok, Input}.
