%% @doc The fail tool: for tests. Reads its mode from the input. In error mode
%% it returns {error, Reason}, where Reason comes from the input (default a
%% fixed atom). In crash mode it raises error(Reason) instead of returning a
%% value. Effect is identity.
-module(soma_tool_fail).

-behaviour(soma_tool).

-export([describe/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => fail,
      effect => identity,
      idempotent => true,
      timeout_ms => 1000}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {error, soma_tool:error()} | no_return().
invoke(#{mode := crash} = Input, _Ctx) ->
    Reason = maps:get(reason, Input, failed),
    error(Reason);
invoke(#{mode := error} = Input, _Ctx) ->
    Reason = maps:get(reason, Input, failed),
    {error, Reason}.
