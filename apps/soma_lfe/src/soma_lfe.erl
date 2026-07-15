%% @doc Soma LFE compiler boundary.
%%
%% compile/2 reads LFE source through soma_lfe_reader, then walks the raw
%% form list through soma_lfe_parser to produce an internal run representation.
-module(soma_lfe).

-export([compile/2, compile_file/2]).

%% @doc Compile LFE source (binary or string) to an internal run map.
%%
%% Returns {ok, #{run => #{steps => [...]}}} on success, or
%% {error, [#{message => binary(), line => non_neg_integer()}]} on failure.
-spec compile(binary() | string(), map()) ->
    {ok, map()} | {error, [map()]}.
compile(Source, _Opts) when is_list(Source) ->
    compile(list_to_binary(Source), _Opts);
compile(Source, _Opts) when is_binary(Source) ->
    case soma_lfe_reader:read_forms(Source) of
        {ok, Forms} ->
            dispatch(Forms);
        {error, Diags} ->
            {error, Diags}
    end.

%% Route on the top-level head: a single (msg ...) form parses to an actor
%% envelope; anything else stays on the run path.
dispatch([[msg | _] = Form]) ->
    soma_lfe_parser:parse_msg(Form);
dispatch([[task | _] = Form]) ->
    soma_lfe_parser:parse_task(Form);
dispatch([[explore | _] = Form]) ->
    soma_lfe_parser:parse_explore(Form);
dispatch([[invoke | _] = Form]) ->
    soma_lfe_parser:parse_invoke(Form);
dispatch([[reply | _] = Form]) ->
    soma_lfe_parser:parse_proposal(Form);
dispatch([['run-steps' | _] = Form]) ->
    soma_lfe_parser:parse_proposal(Form);
dispatch([[reject | _] = Form]) ->
    soma_lfe_parser:parse_proposal(Form);
dispatch([[ask | _] = Form]) ->
    soma_lfe_parser:parse_ask(Form);
dispatch([[trace | _] = Form]) ->
    soma_lfe_parser:parse_trace(Form);
dispatch([[status | _] = Form]) ->
    soma_lfe_parser:parse_status(Form);
dispatch([[result | _] = Form]) ->
    soma_lfe_parser:parse_result(Form);
dispatch([[cancel | _] = Form]) ->
    soma_lfe_parser:parse_cancel(Form);
dispatch([[stop | _] = Form]) ->
    soma_lfe_parser:parse_stop(Form);
dispatch(Forms) ->
    soma_lfe_parser:parse_run(Forms).

%% @doc Compile an LFE source file to an internal run map.
%%
%% Returns {error, Diagnostics} if the file does not exist.
-spec compile_file(file:filename_all(), map()) ->
    {ok, map()} | {error, [map()]}.
compile_file(Path, Opts) ->
    case filelib:is_regular(Path) of
        true ->
            case file:read_file(Path) of
                {ok, Source} ->
                    compile(Source, Opts);
                {error, Reason} ->
                    {error, [#{message => iolist_to_binary(
                                    io_lib:format("file read error: ~p", [Reason])),
                               line => 0}]}
            end;
        false ->
            {error, [#{message => <<"file not found">>, line => 0}]}
    end.
