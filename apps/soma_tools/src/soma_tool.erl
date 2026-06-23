%% @doc The tool behaviour. A tool declares its metadata via describe/0 and
%% does its work via invoke/2. This module is contract only: no logic.
-module(soma_tool).

-export_type([spec/0, input/0, ctx/0, output/0, error/0]).

-type spec() :: map().
-type input() :: term().
-type ctx() :: map().
-type output() :: term().
-type error() :: term().

-callback describe() -> spec().
-callback invoke(input(), ctx()) -> {ok, output()} | {error, error()}.
