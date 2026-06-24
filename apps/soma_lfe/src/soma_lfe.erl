%% @doc Soma LFE compiler boundary.
%%
%% Placeholder implementation. compile/2 and compile_file/2 return well-formed
%% {ok, Steps} or {error, Diagnostics} shapes so callers can write real test
%% assertions today. TODO: replace with a real LFE grammar when the grammar
%% is implemented.
-module(soma_lfe).

-export([compile/2, compile_file/2]).

%% @doc Compile LFE source (binary or string) to a step list.
%%
%% Returns {ok, []} for any input. The step list is empty because no grammar
%% exists yet; subsequent issues will fill in the real compiler.
-spec compile(binary() | string(), map()) ->
    {ok, [map()]} | {error, [map()]}.
compile(_Source, _Opts) ->
    {ok, []}.

%% @doc Compile an LFE source file to a step list.
%%
%% Returns {error, Diagnostics} if the file does not exist.
-spec compile_file(file:filename_all(), map()) ->
    {ok, [map()]} | {error, [map()]}.
compile_file(Path, _Opts) ->
    case filelib:is_regular(Path) of
        true ->
            {ok, []};
        false ->
            {error, [#{message => <<"file not found">>, line => 0}]}
    end.
