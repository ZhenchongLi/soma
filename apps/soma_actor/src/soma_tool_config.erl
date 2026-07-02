%% @doc Config-registered cli tools (#205): load a directory of `(tool ...)'
%% files at daemon boot and register each one through the same
%% `soma_tool_registry:register_tool/1' path the built-ins take.
%%
%% The loader compiles each file to a manifest map and lets `register_tool/1'
%% run `soma_tool_manifest:normalize/1' — it does not validate manifests
%% itself. The one compile-stage rejection is the adapter: config files can
%% only declare `cli' tools, never inject modules. Conservative defaults are
%% filled before registration: `effect => state', `idempotent => false',
%% `timeout_ms => 30000' (never guess a tool is safe).
%%
%% Any per-file failure — read error, parse diagnostic, compile error, or a
%% `{error, _}' from `register_tool/1' — skips that file with one boot log
%% line and a named skip entry; the loop continues. A missing or unreadable
%% directory returns the empty result with no log and no registry call, so
%% boot stays unchanged.
%%
%% Atom policy: the tool name arrives as a string and becomes an atom here —
%% at boot only, from the user's own trusted local files, bounded by file
%% count. Nothing on the wire mints atoms.
%%
%% The runtime never imports this module; the one-way dependency holds.
-module(soma_tool_config).

-export([load_dir/1, compile_form/1]).

%% Conservative defaults for the shared manifest fields a tool file may
%% leave out. Declared values pass through untouched — including invalid
%% ones, so `soma_tool_manifest:normalize/1' stays the validator.
-define(DEFAULTS, #{effect => state,
                    idempotent => false,
                    timeout_ms => 30000}).

-type skip_entry() :: #{file := file:filename(), reason := term()}.
-type result() :: #{registered := [atom()], skipped := [skip_entry()]}.

%% @doc Load every `Dir/*.lisp' tool file, sorted by name, registering each
%% valid one and skipping each broken one with a named diagnostic.
-spec load_dir(file:filename_all()) -> result().
load_dir(Dir) ->
    %% A missing or unreadable directory wildcards to `[]', so the fold never
    %% runs: no log line, no registry call — the empty result.
    Files = lists:sort(filelib:wildcard(filename:join(Dir, "*.lisp"))),
    {Registered, Skipped} =
        lists:foldl(fun load_file/2, {[], []}, Files),
    #{registered => lists:reverse(Registered),
      skipped => lists:reverse(Skipped)}.

%% Register one file, folding the outcome into the accumulator. Any failure
%% skips the file — one warning log line plus a named skip entry — and the
%% fold continues to the next file; a broken tool file never stops boot.
load_file(Path, {Registered, Skipped}) ->
    case register_file(Path, Registered) of
        {ok, Name} ->
            {[Name | Registered], Skipped};
        {error, Reason} ->
            Basename = filename:basename(Path),
            logger:warning("soma tool config: skipped ~s: ~p",
                           [Basename, Reason]),
            {Registered, [#{file => Basename, reason => Reason} | Skipped]}
    end.

%% Read → parse → compile → register, failing closed with bounded named
%% reasons at each edge.
register_file(Path, Registered) ->
    case file:read_file(Path) of
        {ok, Source} ->
            case soma_lfe_reader:read_forms(Source) of
                {ok, [Form]} ->
                    compile_and_register(Form, Registered);
                {ok, Forms} ->
                    {error, {expected_one_tool_form, length(Forms)}};
                {error, Diagnostics} ->
                    {error, {parse_error, Diagnostics}}
            end;
        {error, Reason} ->
            {error, {read_error, Reason}}
    end.

compile_and_register(Form, Registered) ->
    case compile_tool(Form) of
        {ok, Manifest} ->
            register_manifest(Manifest, Registered);
        {error, _} = Error ->
            Error
    end.

%% Admission gate in front of `register_tool/1'. Reserved first: a config
%% file may not declare a built-in tool's name — the registry overwrites by
%% name, and the resume fail-safe reads `effect' / `idempotent' off exactly
%% those descriptors, so a shadow would soften it (the reserved set comes
%% from `soma_tool_registry:builtin_names/0', the seed list's own names,
%% never a retyped list here). Then duplicate: a name already registered by
%% an earlier file *in this load* skips, so the first file in sorted order
%% wins with a diagnostic instead of silent last-write-wins. The duplicate
%% check is per-load (the fold accumulator), not against the live registry —
%% re-loading a directory must keep working.
register_manifest(#{name := Name} = Manifest, Registered) ->
    case lists:member(Name, soma_tool_registry:builtin_names()) of
        true ->
            {error, {reserved_name, Name}};
        false ->
            case lists:member(Name, Registered) of
                true ->
                    {error, {duplicate_name, Name}};
                false ->
                    case soma_tool_registry:register_tool(Manifest) of
                        ok -> {ok, Name};
                        {error, _} = Error -> Error
                    end
            end
    end.

%% @doc Compile a parsed `(tool ...)' form into the manifest map
%% `register_tool/1' normalizes -- the one shared compiler a socket register
%% handler reuses so a socket register and a boot-file load validate the same
%% `(tool ...)' grammar through one path (never a second copy of it).
-spec compile_form(term()) -> {ok, map()} | {error, term()}.
compile_form(Form) ->
    compile_tool(Form).

%% Compile a parsed `(tool (key value...) ...)' form into the manifest map
%% `register_tool/1' normalizes. Grammar errors (unknown key, duplicate key,
%% wrong value shape where this compiler must transform the value, missing
%% name, a non-cli adapter) are named compile errors; value shapes normalize
%% already checks (effect membership, boolean, integer range) pass through so
%% its error names win.
compile_tool([tool | Entries]) ->
    case collect_fields(Entries, #{}) of
        {ok, Fields} -> build_manifest(Fields);
        {error, _} = Error -> Error
    end;
compile_tool(_Form) ->
    {error, not_a_tool_form}.

collect_fields([], Fields) ->
    {ok, Fields};
collect_fields([Entry | Rest], Fields) ->
    case compile_entry(Entry) of
        {ok, {Key, Value}} ->
            case maps:is_key(Key, Fields) of
                true -> {error, {duplicate_key, Key}};
                false -> collect_fields(Rest, Fields#{Key => Value})
            end;
        {error, _} = Error ->
            Error
    end;
collect_fields(_Improper, _Fields) ->
    {error, invalid_tool_form}.

%% One `(key value...)' entry compiled to its manifest field. `name',
%% `description', and `executable' take one string; `argv' takes zero or more
%% strings; `params' takes the documented compact param rows and maps them to
%% manifest param specs; `effect', `idempotent', and `adapter' take one value
%% normalize (or the adapter gate) judges; `timeout-ms' takes one value and maps
%% to the manifest key `timeout_ms'.
compile_entry([name, Value]) when is_binary(Value) ->
    {ok, {name, Value}};
compile_entry([description, Value]) when is_binary(Value) ->
    {ok, {description, Value}};
compile_entry([executable, Value]) when is_binary(Value) ->
    {ok, {executable, Value}};
compile_entry([argv | Values]) ->
    case lists:all(fun is_binary/1, Values) of
        true -> {ok, {argv, Values}};
        false -> {error, {invalid_value, argv, Values}}
    end;
compile_entry([params, Specs]) when is_list(Specs) ->
    compile_params(Specs);
compile_entry([effect, Value]) ->
    {ok, {effect, Value}};
compile_entry([idempotent, Value]) ->
    {ok, {idempotent, Value}};
compile_entry([adapter, Value]) ->
    {ok, {adapter, Value}};
compile_entry(['timeout-ms', Value]) ->
    {ok, {timeout_ms, Value}};
compile_entry([Key, _Value]) when Key =:= name;
                                  Key =:= description;
                                  Key =:= executable ->
    {error, {invalid_value, Key, string_required}};
compile_entry([Key | Values]) when Key =:= name;
                                   Key =:= description;
                                   Key =:= executable;
                                   Key =:= params;
                                   Key =:= effect;
                                   Key =:= idempotent;
                                   Key =:= adapter;
                                   Key =:= 'timeout-ms' ->
    {error, {invalid_value, Key, Values}};
compile_entry([Key | _Values]) when is_atom(Key) ->
    {error, {unknown_key, Key}};
compile_entry(Entry) ->
    {error, {invalid_entry, Entry}}.

compile_params(Specs) ->
    compile_params(Specs, []).

compile_params([], Acc) ->
    {ok, {params, lists:reverse(Acc)}};
compile_params([Spec | Rest], Acc) ->
    case compile_param_spec(Spec) of
        {ok, Param} -> compile_params(Rest, [Param | Acc]);
        {error, _} = Error -> Error
    end;
compile_params(ImproperTail, _Acc) ->
    {error, {invalid_value, params, ImproperTail}}.

compile_param_spec([Name, Type, Required]) ->
    {ok, #{name => Name,
           type => Type,
           required => compile_param_required(Required)}};
compile_param_spec([Name, Type, Required, Doc]) ->
    {ok, #{name => Name,
           type => Type,
           required => compile_param_required(Required),
           doc => Doc}};
compile_param_spec(Spec) ->
    {error, {invalid_value, params, Spec}}.

compile_param_required(required) ->
    true;
compile_param_required(optional) ->
    false;
compile_param_required(Required) ->
    Required.

%% Assemble the manifest: require a name, gate the adapter to `cli' (config
%% files cannot inject modules — `(adapter erlang_module)' must never fall
%% through to normalize), fill the conservative defaults, and mint the name
%% atom (boot-only, trusted local file).
build_manifest(Fields) ->
    case Fields of
        #{name := NameBin} ->
            case maps:get(adapter, Fields, cli) of
                cli ->
                    Name = binary_to_atom(NameBin, utf8),
                    Manifest = maps:merge(?DEFAULTS,
                                          Fields#{name => Name,
                                                  adapter => cli}),
                    {ok, Manifest};
                Other ->
                    {error, {adapter_not_allowed, Other}}
            end;
        _ ->
            {error, missing_name}
    end.
