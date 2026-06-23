%% @doc The file.read tool: reads the bytes of a file that lives under the
%% sandbox root supplied in ctx. The path comes from the input and is resolved
%% against the root. Effect is reader.
-module(soma_tool_file_read).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => file_read,
      effect => reader,
      idempotent => true,
      timeout_ms => 1000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module, module => ?MODULE}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
invoke(#{path := Path}, #{root := Root}) ->
    case soma_tool_file:resolve_under_root(Root, Path) of
        {ok, Full} ->
            case file:read_file(Full) of
                {ok, Bytes} -> {ok, Bytes};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
