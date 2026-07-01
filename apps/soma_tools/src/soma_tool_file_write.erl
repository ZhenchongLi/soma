%% @doc The file.write tool: writes the bytes from the input to a file that
%% lives under the sandbox root supplied in ctx. The path comes from the input
%% and is resolved against the root. Effect is state.
-module(soma_tool_file_write).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => file_write,
      effect => state,
      idempotent => false,
      timeout_ms => 1000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module,
                  module => ?MODULE,
                  description =>
                      <<"Writes the given bytes to a file under the "
                        "sandbox root.">>,
                  params => [#{name => <<"path">>,
                               type => string,
                               required => true,
                               doc => <<"File path, resolved against "
                                        "the sandbox root.">>},
                             #{name => <<"bytes">>,
                               type => string,
                               required => true,
                               doc => <<"The bytes to write.">>}]}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
invoke(#{path := Path, bytes := Bytes}, #{root := Root}) ->
    case soma_tool_file:resolve_under_root(Root, Path) of
        {ok, Full} ->
            case file:write_file(Full, Bytes) of
                ok -> {ok, byte_size(Bytes)};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
