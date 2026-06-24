-module(soma_actor_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([actor_is_gen_statem_with_callbacks/1]).

all() ->
    [actor_is_gen_statem_with_callbacks].

%% Criterion 1: soma_actor implements the gen_statem behaviour and exports
%% start_link/1, callback_mode/0, and init/1. Proven by module introspection;
%% compilation against the gen_statem behaviour is itself part of the proof.
actor_is_gen_statem_with_callbacks(_Config) ->
    Attributes = soma_actor:module_info(attributes),
    Behaviours = proplists:get_value(behaviour, Attributes, []),
    true = lists:member(gen_statem, Behaviours),
    Exports = soma_actor:module_info(exports),
    true = lists:member({start_link, 1}, Exports),
    true = lists:member({callback_mode, 0}, Exports),
    true = lists:member({init, 1}, Exports),
    ok.
