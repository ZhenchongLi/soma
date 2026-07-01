%% @doc Test-only tool that violates the in-BEAM tool callback return contract.
-module(soma_tool_bad_return).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => bad_return,
      effect => identity,
      idempotent => true,
      timeout_ms => 1000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module, module => ?MODULE}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) -> term().
invoke(_Input, _Ctx) ->
    #{unexpected => binary:copy(<<"x">>, 4096)}.
