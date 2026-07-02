%% @doc The tool registry. Two shapes share this module:
%%
%%   * the pure `name => descriptor' map functions `register/3', `lookup/2',
%%     `names/1' (used directly by unit tests); and
%%   * a `gen_server' wrapper started under `soma_sup' that holds one seeded
%%     registry map as its state, so the runtime resolves tools through a
%%     single shared process.
%%
%% A descriptor names the adapter that runs a tool and, for an `erlang_module'
%% tool, the backing module: `#{adapter => erlang_module, module => Module}'.
%% The `adapter' vocabulary is shared with the manifest contract
%% (`docs/tool-manifest.md').
-module(soma_tool_registry).

-behaviour(gen_server).

%% Pure map API
-export([register/3, lookup/2, names/1, catalog/1, list_tools/1,
         builtin_names/0]).

%% Process API
-export([start_link/0, register_tool/1, resolve/1, resolve_descriptor/1,
         catalog/0, list_tools/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2]).

%% A descriptor is a normalized manifest. Two shapes share the type: an
%% `erlang_module' tool carries `module'; a `cli' tool carries `executable' and
%% `argv'. `resolve/1' reads `module' out of a descriptor and so is only valid
%% for `erlang_module' tools; `resolve_descriptor/1' hands the descriptor back
%% whole and is the path a `cli' caller branches on `adapter' through.
%% Both shapes may additionally carry the optional model-facing half:
%% `description' (binary) and `params' (a list of param-spec maps). The
%% catalog is built from those two fields alone.
-type descriptor() :: #{name := atom(),
                        effect := atom(),
                        idempotent := boolean(),
                        timeout_ms := non_neg_integer(),
                        adapter := erlang_module,
                        module := module(),
                        description => binary(),
                        params => [map()]}
                    | #{name := atom(),
                        effect := atom(),
                        idempotent := boolean(),
                        timeout_ms := non_neg_integer(),
                        adapter := cli,
                        executable := string() | binary(),
                        argv := [string() | binary()],
                        description => binary(),
                        params => [map()]}.
-type registry() :: #{atom() => descriptor()}.
-type catalog_entry() :: #{name := atom(),
                           description := binary(),
                           params := [map()]}.
-type tool_summary() :: #{name := atom(),
                          effect := atom(),
                          idempotent := boolean(),
                          adapter := erlang_module | cli,
                          description => binary()}.

-export_type([descriptor/0, registry/0, catalog_entry/0, tool_summary/0]).

%% The backing modules for the five built-in tools. Each one exports
%% `manifest/0'; the seed is built by normalizing those manifests, so the
%% registry descriptors come from the same contract the manifest tests check.
-define(BUILTIN_MODULES, [soma_tool_echo,
                          soma_tool_sleep,
                          soma_tool_fail,
                          soma_tool_file_read,
                          soma_tool_file_write]).

-spec register(registry(), atom(), descriptor()) -> registry().
register(Registry, Name, Descriptor) ->
    Registry#{Name => Descriptor}.

-spec lookup(registry(), atom()) -> {ok, descriptor()} | {error, not_found}.
lookup(Registry, Name) ->
    case Registry of
        #{Name := Descriptor} -> {ok, Descriptor};
        _ -> {error, not_found}
    end.

-spec names(registry()) -> [atom()].
names(Registry) ->
    maps:keys(Registry).

%% @doc The names of the built-in tools, derived from the same
%% `?BUILTIN_MODULES' seed list `seed/0' builds the registry from — one
%% source of truth, so a new built-in extends the reserved set
%% automatically. Read-only: no registry state is touched.
-spec builtin_names() -> [atom()].
builtin_names() ->
    [maps:get(name, Module:manifest()) || Module <- ?BUILTIN_MODULES].

%% @doc The model-facing catalog of a registry map: one entry per descriptor
%% that carries a `description'. Each entry is constructed as exactly
%% `#{name, description, params}' — never filtered down from the descriptor —
%% so runtime internals (`module', `executable', `argv', `effect',
%% `idempotent', `timeout_ms') cannot leak. `params' defaults to `[]' when the
%% descriptor declares none. Entries are sorted by name.
-spec catalog(registry()) -> [catalog_entry()].
catalog(Registry) ->
    Entries =
        maps:fold(
          fun(Name, #{description := Description} = Descriptor, Acc) ->
                  [#{name => Name,
                     description => Description,
                     params => maps:get(params, Descriptor, [])} | Acc];
             (_Name, _Descriptor, Acc) ->
                  Acc
          end,
          [],
          Registry),
    lists:sort(fun(#{name := A}, #{name := B}) -> A =< B end, Entries).

%% @doc The operator-facing list projection of a registry map: one entry per
%% live descriptor — every tool appears, unlike `catalog/1'. Each entry is
%% constructed as exactly `#{name, effect, idempotent, adapter}' from named
%% fields — never filtered down from the descriptor — so runtime internals
%% (`module', `executable', `argv', `timeout_ms') cannot leak. `description'
%% is carried only when the descriptor declares one. Entries are sorted by
%% name.
-spec list_tools(registry()) -> [tool_summary()].
list_tools(Registry) ->
    Entries =
        maps:fold(
          fun(Name, #{effect := Effect, idempotent := Idempotent,
                      adapter := Adapter} = Descriptor, Acc) ->
                  Base = #{name => Name,
                           effect => Effect,
                           idempotent => Idempotent,
                           adapter => Adapter},
                  Entry = case maps:find(description, Descriptor) of
                              {ok, Description} ->
                                  Base#{description => Description};
                              error ->
                                  Base
                          end,
                  [Entry | Acc]
          end,
          [],
          Registry),
    lists:sort(fun(#{name := A}, #{name := B}) -> A =< B end, Entries).

%%% Process API

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register a tool manifest into the running registry. The manifest is
%% normalized through `soma_tool_manifest:normalize/1' first — the same rule the
%% seed build follows — so a malformed manifest is rejected before it lands in
%% the registry map. The resulting descriptor is keyed by its declared `name'.
-spec register_tool(map()) -> ok | {error, term()}.
register_tool(Manifest) ->
    gen_server:call(?MODULE, {register_tool, Manifest}).

%% @doc Resolve a tool name to its module through the running registry.
-spec resolve(atom()) -> {ok, module()} | {error, not_found}.
resolve(Name) ->
    gen_server:call(?MODULE, {resolve, Name}).

%% @doc Resolve a tool name to its full descriptor through the running registry.
-spec resolve_descriptor(atom()) -> {ok, descriptor()} | {error, not_found}.
resolve_descriptor(Name) ->
    gen_server:call(?MODULE, {resolve_descriptor, Name}).

%% @doc The model-facing catalog of the running registry. See `catalog/1'.
-spec catalog() -> [catalog_entry()].
catalog() ->
    gen_server:call(?MODULE, catalog).

%% @doc The operator-facing list projection of the running registry. See
%% `list_tools/1'.
-spec list_tools() -> [tool_summary()].
list_tools() ->
    gen_server:call(?MODULE, list_tools).

%%% gen_server callbacks

init([]) ->
    {ok, seed()}.

%% Build the seed registry from the built-in manifests: normalize each module's
%% `manifest/0' and key the resulting descriptor by its declared `name'. A
%% manifest that fails `normalize/1' crashes the seed build, so a malformed
%% built-in manifest stops the registry from starting rather than seeding a bad
%% descriptor.
-spec seed() -> registry().
seed() ->
    lists:foldl(
      fun(Module, Acc) ->
          {ok, Descriptor} = soma_tool_manifest:normalize(Module:manifest()),
          #{name := Name} = Descriptor,
          Acc#{Name => Descriptor}
      end,
      #{},
      ?BUILTIN_MODULES).

handle_call({register_tool, Manifest}, _From, Registry) ->
    case soma_tool_manifest:normalize(Manifest) of
        {ok, Descriptor} ->
            #{name := Name} = Descriptor,
            {reply, ok, register(Registry, Name, Descriptor)};
        {error, _} = Error ->
            {reply, Error, Registry}
    end;
handle_call({resolve, Name}, _From, Registry) ->
    %% `resolve/1' keeps its bare-module shape by reading `module' out of the
    %% stored descriptor, so the seed map holds descriptors as the one source
    %% of truth.
    Reply = case lookup(Registry, Name) of
                {ok, #{module := Module}} -> {ok, Module};
                {error, not_found} -> {error, not_found}
            end,
    {reply, Reply, Registry};
handle_call({resolve_descriptor, Name}, _From, Registry) ->
    {reply, lookup(Registry, Name), Registry};
handle_call(catalog, _From, Registry) ->
    {reply, catalog(Registry), Registry};
handle_call(list_tools, _From, Registry) ->
    {reply, list_tools(Registry), Registry};
handle_call(_Msg, _From, Registry) ->
    {reply, {error, unknown_call}, Registry}.

handle_cast(_Msg, Registry) ->
    {noreply, Registry}.
