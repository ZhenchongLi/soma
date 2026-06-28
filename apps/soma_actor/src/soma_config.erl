%% @doc Reads the tiny `~/.soma/config' TOML subset and assembles the
%% `model_config' map the actor consumes.
%%
%% This slice implements only the base provider map: an `[llm]' table with
%% `provider', `base_url', and `model'. The path resolves from the `config_path'
%% option when supplied (the hermetic-test seam).
%%
%% The runtime never imports this module; the one-way dependency holds.
-module(soma_config).

-export([load/1]).

%% @doc Load the model config from the resolved path.
-spec load(map()) -> map() | undefined.
load(Opts) ->
    Path = resolve_path(Opts),
    Llm = read_llm_table(Path),
    build_model_config(Llm).

resolve_path(Opts) ->
    maps:get(config_path, Opts).

%% Parse the file and return the key/value pairs found under the [llm] table,
%% as a map of binary key => parsed value.
read_llm_table(Path) ->
    {ok, Bin} = file:read_file(Path),
    Lines = string:split(unicode:characters_to_list(Bin), "\n", all),
    collect_llm(Lines, outside, #{}).

collect_llm([], _Table, Acc) ->
    Acc;
collect_llm([Line | Rest], Table, Acc) ->
    case classify(string:trim(Line)) of
        blank ->
            collect_llm(Rest, Table, Acc);
        comment ->
            collect_llm(Rest, Table, Acc);
        {table, Name} ->
            collect_llm(Rest, Name, Acc);
        {kv, Key, Value} when Table =:= "llm" ->
            collect_llm(Rest, Table, Acc#{Key => Value});
        {kv, _Key, _Value} ->
            collect_llm(Rest, Table, Acc)
    end.

classify("") ->
    blank;
classify("#" ++ _) ->
    comment;
classify("[" ++ Rest) ->
    {table, string:trim(Rest, trailing, "]")};
classify(Line) ->
    case string:split(Line, "=") of
        [RawKey, RawValue] ->
            Key = string:trim(RawKey),
            Value = parse_value(string:trim(RawValue)),
            {kv, Key, Value};
        _ ->
            blank
    end.

parse_value([$" | _] = Quoted) ->
    Stripped = string:trim(Quoted, both, "\""),
    list_to_binary(Stripped);
parse_value("true") ->
    true;
parse_value("false") ->
    false;
parse_value(Raw) ->
    list_to_integer(Raw).

build_model_config(Llm) when map_size(Llm) =:= 0 ->
    undefined;
build_model_config(Llm) ->
    Provider = provider_atom(maps:get("provider", Llm)),
    #{
        provider => Provider,
        base_url => maps:get("base_url", Llm),
        model => maps:get("model", Llm)
    }.

provider_atom(<<"openai_compat">>) ->
    openai_compat.
