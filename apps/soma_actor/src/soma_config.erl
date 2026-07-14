%% @doc Reads the tiny `~/.soma/config' TOML subset and assembles the
%% `model_config' map the actor consumes.
%%
%% This slice implements the provider map from an `[llm]' table: `provider',
%% `base_url', `model', and optional planning / provider knobs. The path resolves
%% from the `config_path' option when supplied (the hermetic-test seam).
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

%% The path resolves from the `config_path' option when supplied (the
%% hermetic-test seam), else the `SOMA_CONFIG' env var, else the `$HOME'-expanded
%% `~/.soma/config' default.
resolve_path(#{config_path := Path}) ->
    Path;
resolve_path(_Opts) ->
    case os:getenv("SOMA_CONFIG") of
        false -> default_config_path();
        "" -> default_config_path();
        Path -> Path
    end.

default_config_path() ->
    case os:getenv("HOME") of
        false -> "/.soma/config";
        Home -> filename:join([Home, ".soma", "config"])
    end.

%% Parse the file and return the key/value pairs found under the [llm] table,
%% as a map of binary key => parsed value.
read_llm_table(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = string:split(unicode:characters_to_list(Bin), "\n", all),
            collect_llm(Lines, outside, #{});
        {error, _} ->
            #{}
    end.

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
    Provider = provider_atom(require("provider", Llm, missing_llm_provider)),
    Base0 = #{
        provider => Provider,
        base_url => require("base_url", Llm, missing_openai_base_url),
        model => require("model", Llm, missing_openai_model)
    },
    Base = carry_api_key(Base0),
    lists:foldl(fun(Key, Acc) -> carry_optional(Key, Llm, Acc) end,
                Base, ["enable_thinking", "max_tokens", "plan", "explore",
                       "max_explore_rounds", "max_observation_bytes"]).

require(Key, Llm, ErrorName) ->
    case maps:find(Key, Llm) of
        {ok, Value} -> Value;
        error -> error({config_error, ErrorName})
    end.

carry_api_key(Acc) ->
    case os:getenv("SOMA_LLM_API_KEY") of
        false -> error({missing_env, "SOMA_LLM_API_KEY"});
        "" -> error({missing_env, "SOMA_LLM_API_KEY"});
        Value -> Acc#{api_key => list_to_binary(Value)}
    end.

carry_optional(Key, Llm, Acc) ->
    case maps:find(Key, Llm) of
        {ok, Value} -> Acc#{list_to_atom(Key) => Value};
        error -> Acc
    end.

provider_atom(<<"openai_compat">>) ->
    openai_compat;
provider_atom(Other) ->
    error({config_error, {unsupported_llm_provider, Other}}).
