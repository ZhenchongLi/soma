%% @doc The tool registry. Two shapes share this module:
%%
%%   * the pure `name => module' map functions `register/3', `lookup/2',
%%     `names/1' (used directly by unit tests); and
%%   * a `gen_server' wrapper started under `soma_sup' that holds one seeded
%%     registry map as its state, so the runtime resolves tools through a
%%     single shared process.
-module(soma_tool_registry).

-behaviour(gen_server).

%% Pure map API
-export([register/3, lookup/2, names/1]).

%% Process API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2]).

-type registry() :: #{atom() => module()}.

-export_type([registry/0]).

-define(SEED, #{echo => soma_tool_echo,
                sleep => soma_tool_sleep,
                fail => soma_tool_fail,
                file_read => soma_tool_file_read,
                file_write => soma_tool_file_write}).

-spec register(registry(), atom(), module()) -> registry().
register(Registry, Name, Module) ->
    Registry#{Name => Module}.

-spec lookup(registry(), atom()) -> {ok, module()} | {error, not_found}.
lookup(Registry, Name) ->
    case Registry of
        #{Name := Module} -> {ok, Module};
        _ -> {error, not_found}
    end.

-spec names(registry()) -> [atom()].
names(Registry) ->
    maps:keys(Registry).

%%% Process API

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%% gen_server callbacks

init([]) ->
    {ok, ?SEED}.

handle_call(_Msg, _From, Registry) ->
    {reply, {error, unknown_call}, Registry}.

handle_cast(_Msg, Registry) ->
    {noreply, Registry}.
