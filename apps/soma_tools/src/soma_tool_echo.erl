%% @doc The echo tool: returns its input unchanged. Effect is identity.
-module(soma_tool_echo).

-behaviour(soma_tool).

-export([describe/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => echo,
      effect => identity,
      idempotent => true,
      timeout_ms => 1000}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()}.
invoke(Input, _Ctx) ->
    {ok, Input}.
