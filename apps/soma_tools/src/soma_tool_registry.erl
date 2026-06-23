%% @doc The tool registry: a pure `name => module' map. `register/3' adds a
%% binding and returns the updated map; `lookup/2' reads a binding back.
-module(soma_tool_registry).

-export([register/3, lookup/2]).

-type registry() :: #{atom() => module()}.

-export_type([registry/0]).

-spec register(registry(), atom(), module()) -> registry().
register(Registry, Name, Module) ->
    Registry#{Name => Module}.

-spec lookup(registry(), atom()) -> {ok, module()} | {error, not_found}.
lookup(Registry, Name) ->
    case Registry of
        #{Name := Module} -> {ok, Module};
        _ -> {error, not_found}
    end.
