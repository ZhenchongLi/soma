-module(soma_tool_manifest).

-export([normalize/1]).

-define(SHARED_FIELDS, [name, effect, idempotent, timeout_ms, adapter]).
-define(EFFECTS, [identity, reader, state]).
-define(ADAPTERS, [erlang_module, cli]).
-define(PARAM_TYPES, [string, integer, boolean]).

-spec normalize(map()) -> {ok, map()} | {error, term()}.
normalize(Manifest) when is_map(Manifest) ->
    case missing_shared_field(Manifest) of
        {missing, Key} -> {error, {missing_field, Key}};
        none -> check_name(Manifest)
    end.

missing_shared_field(Manifest) ->
    case [K || K <- ?SHARED_FIELDS, not maps:is_key(K, Manifest)] of
        [Key | _] -> {missing, Key};
        [] -> none
    end.

%% Tool names are either the literal atoms declared by built-in modules or
%% UTF-8 binaries admitted from config. Keep external names bounded without
%% copying their spelling into an error term. The limit is Unicode codepoints,
%% not encoded bytes.
check_name(#{name := Name} = Manifest) when is_atom(Name) ->
    check_effect(Manifest);
check_name(#{name := Name} = Manifest) when is_binary(Name) ->
    try unicode:characters_to_list(Name, utf8) of
        Characters when is_list(Characters) ->
            case length(Characters) =< 255 of
                true -> check_effect(Manifest);
                false -> {error, {invalid_tool_name, too_long}}
            end;
        _InvalidUnicode ->
            {error, {invalid_tool_name, invalid_utf8}}
    catch
        error:badarg -> {error, {invalid_tool_name, invalid_utf8}}
    end;
check_name(_Manifest) ->
    {error, {invalid_tool_name, invalid_type}}.

check_effect(#{effect := Effect} = Manifest) ->
    case lists:member(Effect, ?EFFECTS) of
        true -> check_idempotent(Manifest);
        false -> {error, {invalid_effect, Effect}}
    end.

check_idempotent(#{idempotent := Idempotent} = Manifest) ->
    case is_boolean(Idempotent) of
        true -> check_timeout_ms(Manifest);
        false -> {error, {invalid_idempotent, Idempotent}}
    end.

check_timeout_ms(#{timeout_ms := TimeoutMs} = Manifest) ->
    case is_integer(TimeoutMs) andalso TimeoutMs > 0 of
        true -> check_adapter(Manifest);
        false -> {error, {invalid_timeout_ms, TimeoutMs}}
    end.

check_adapter(#{adapter := Adapter} = Manifest) ->
    case lists:member(Adapter, ?ADAPTERS) of
        true -> check_adapter_fields(Manifest);
        false -> {error, {invalid_adapter, Adapter}}
    end.

check_adapter_fields(#{adapter := erlang_module} = Manifest) ->
    case maps:is_key(module, Manifest) of
        true -> check_model_facing(Manifest);
        false -> {error, {missing_field, module}}
    end;
check_adapter_fields(#{adapter := cli, executable := Executable, argv := Argv} = Manifest) ->
    case has_internal_whitespace(Executable) of
        true -> {error, {invalid_executable, Executable}};
        false ->
            case is_list(Argv) of
                true -> check_model_facing(Manifest);
                false -> {error, {invalid_argv, Argv}}
            end
    end;
check_adapter_fields(#{adapter := cli} = Manifest) ->
    case [K || K <- [executable, argv], not maps:is_key(K, Manifest)] of
        [Key | _] -> {error, {missing_field, Key}};
        [] -> check_model_facing(Manifest)
    end;
check_adapter_fields(Manifest) ->
    check_model_facing(Manifest).

%% Optional model-facing half: a binary description plus a params list of
%% #{name (binary), type (string|integer|boolean), required (boolean)} specs,
%% each optionally carrying a binary doc. Absent fields stay absent.
check_model_facing(Manifest) ->
    case check_description(Manifest) of
        ok ->
            case check_params(Manifest) of
                ok ->
                    case check_cli_argv_placeholders(Manifest) of
                        ok -> normalize_complete(Manifest);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

check_description(#{description := Description}) when is_binary(Description) ->
    ok;
check_description(#{description := Description}) ->
    {error, {invalid_description, Description}};
check_description(_) ->
    ok.

check_params(#{params := Params}) when is_list(Params) ->
    check_param_specs(Params);
check_params(#{params := Params}) ->
    {error, {invalid_params, Params}};
check_params(_) ->
    ok.

check_param_specs([]) ->
    ok;
check_param_specs([Spec | Rest]) ->
    case valid_param_spec(Spec) of
        true -> check_param_specs(Rest);
        false -> {error, {invalid_params, Spec}}
    end;
%% An improper tail ([Spec | garbage]) passes is_list/1's head cons-cell check;
%% reject it here instead of crashing the caller with a function_clause.
check_param_specs(ImproperTail) ->
    {error, {invalid_params, ImproperTail}}.

valid_param_spec(#{name := Name, type := Type, required := Required} = Spec) ->
    is_binary(Name) andalso
        lists:member(Type, ?PARAM_TYPES) andalso
        is_boolean(Required) andalso
        valid_param_doc(Spec);
valid_param_spec(_) ->
    false.

valid_param_doc(#{doc := Doc}) ->
    is_binary(Doc);
valid_param_doc(_) ->
    true.

check_cli_argv_placeholders(#{adapter := cli, argv := Argv} = Manifest) ->
    ParamNames = param_names(Manifest),
    case first_unknown_argv_placeholder(Argv, ParamNames) of
        none -> ok;
        {unknown, Name} -> {error, {unknown_argv_placeholder, Name}}
    end;
check_cli_argv_placeholders(_) ->
    ok.

param_names(#{params := Params}) ->
    [Name || #{name := Name} <- Params];
param_names(_) ->
    [].

first_unknown_argv_placeholder([], _ParamNames) ->
    none;
first_unknown_argv_placeholder([Arg | Rest], ParamNames) ->
    case argv_placeholder_name(Arg) of
        {placeholder, Name} ->
            case lists:member(Name, ParamNames) of
                true -> first_unknown_argv_placeholder(Rest, ParamNames);
                false -> {unknown, Name}
            end;
        none ->
            first_unknown_argv_placeholder(Rest, ParamNames)
    end;
first_unknown_argv_placeholder(_ImproperTail, _ParamNames) ->
    none.

argv_placeholder_name(Arg) when is_binary(Arg) ->
    Size = byte_size(Arg),
    case Size >= 2 andalso
        binary:at(Arg, 0) =:= ${ andalso
        binary:at(Arg, Size - 1) =:= $} of
        true ->
            NameSize = Size - 2,
            <<${, Name:NameSize/binary, $}>> = Arg,
            {placeholder, Name};
        false ->
            none
    end;
argv_placeholder_name(Arg) when is_list(Arg) ->
    case unicode:characters_to_binary(Arg) of
        Bin when is_binary(Bin) -> argv_placeholder_name(Bin);
        _ -> none
    end;
argv_placeholder_name(_) ->
    none.

has_internal_whitespace(Executable) when is_binary(Executable) ->
    has_internal_whitespace(binary_to_list(Executable));
has_internal_whitespace(Executable) when is_list(Executable) ->
    lists:any(fun(C) -> C =:= $\s orelse C =:= $\t end, Executable).

normalize_complete(
    #{
        name := Name,
        effect := Effect,
        idempotent := Idempotent,
        timeout_ms := TimeoutMs,
        adapter := erlang_module,
        module := Module
    } = Input
) ->
    Manifest = #{
        name => Name,
        effect => Effect,
        idempotent => Idempotent,
        timeout_ms => TimeoutMs,
        adapter => erlang_module,
        module => Module
    },
    {ok, merge_model_facing(Input, Manifest)};
normalize_complete(
    #{
        name := Name,
        effect := Effect,
        idempotent := Idempotent,
        timeout_ms := TimeoutMs,
        adapter := cli,
        executable := Executable,
        argv := Argv
    } = Input
) ->
    Manifest = #{
        name => Name,
        effect => Effect,
        idempotent => Idempotent,
        timeout_ms => TimeoutMs,
        adapter => cli,
        executable => Executable,
        argv => Argv
    },
    {ok, merge_model_facing(Input, Manifest)}.

%% Carry description/params into the rebuilt descriptor only when the input
%% had them; a manifest without them gains no new keys. Param specs are rebuilt
%% to exactly name/type/required (+ doc when present) so stray keys inside a
%% spec are dropped, keeping normalize/1 idempotent.
merge_model_facing(Input, Descriptor0) ->
    Descriptor =
        case Input of
            #{description := Description} -> Descriptor0#{description => Description};
            _ -> Descriptor0
        end,
    case Input of
        #{params := Params} ->
            Descriptor#{params => [rebuild_param_spec(Spec) || Spec <- Params]};
        _ ->
            Descriptor
    end.

rebuild_param_spec(#{name := Name, type := Type, required := Required} = Spec) ->
    Base = #{name => Name, type => Type, required => Required},
    case Spec of
        #{doc := Doc} -> Base#{doc => Doc};
        _ -> Base
    end.
