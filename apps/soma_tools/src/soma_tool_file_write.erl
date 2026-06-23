%% @doc The file.write tool: writes the bytes from the input to a file that
%% lives under the sandbox root supplied in ctx. The path comes from the input
%% and is resolved against the root. Effect is state.
-module(soma_tool_file_write).

-behaviour(soma_tool).

-export([describe/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => file_write,
      effect => state,
      idempotent => false,
      timeout_ms => 1000}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
invoke(#{path := Path, bytes := Bytes}, #{root := Root}) ->
    Full = filename:join(Root, Path),
    case file:write_file(Full, Bytes) of
        ok -> {ok, byte_size(Bytes)};
        {error, Reason} -> {error, Reason}
    end.
