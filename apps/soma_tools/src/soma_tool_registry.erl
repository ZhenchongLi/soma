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
-export([register/3, lookup/2, names/1]).

%% Process API
-export([start_link/0, resolve/1, resolve_descriptor/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2]).

-type descriptor() :: #{adapter := erlang_module, module := module()}.
-type registry() :: #{atom() => descriptor()}.

-export_type([descriptor/0, registry/0]).

-define(SEED, #{echo => #{adapter => erlang_module, module => soma_tool_echo},
                sleep => #{adapter => erlang_module, module => soma_tool_sleep},
                fail => #{adapter => erlang_module, module => soma_tool_fail},
                file_read => #{adapter => erlang_module, module => soma_tool_file_read},
                file_write => #{adapter => erlang_module, module => soma_tool_file_write}}).

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

%%% Process API

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Resolve a tool name to its module through the running registry.
-spec resolve(atom()) -> {ok, module()} | {error, not_found}.
resolve(Name) ->
    gen_server:call(?MODULE, {resolve, Name}).

%% @doc Resolve a tool name to its full descriptor through the running registry.
-spec resolve_descriptor(atom()) -> {ok, descriptor()} | {error, not_found}.
resolve_descriptor(Name) ->
    gen_server:call(?MODULE, {resolve_descriptor, Name}).

%%% gen_server callbacks

init([]) ->
    {ok, ?SEED}.

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
handle_call(_Msg, _From, Registry) ->
    {reply, {error, unknown_call}, Registry}.

handle_cast(_Msg, Registry) ->
    {noreply, Registry}.
