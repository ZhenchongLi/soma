%% @doc The sleep tool: waits the requested number of milliseconds, then
%% returns its input unchanged. Effect is reader (observes the clock).
-module(soma_tool_sleep).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => sleep,
      effect => reader,
      idempotent => true,
      timeout_ms => 1000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module, module => ?MODULE}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()}.
invoke(#{ms := Ms} = Input, _Ctx) ->
    timer:sleep(Ms),
    {ok, Input}.
