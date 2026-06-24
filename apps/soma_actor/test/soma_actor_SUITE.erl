-module(soma_actor_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([actor_is_gen_statem_with_callbacks/1]).
-export([start_actor_returns_ok_pid/1]).
-export([actor_alive_after_start/1]).

all() ->
    [actor_is_gen_statem_with_callbacks,
     start_actor_returns_ok_pid,
     actor_alive_after_start].

init_per_testcase(TestCase, Config)
  when TestCase =:= start_actor_returns_ok_pid;
       TestCase =:= actor_alive_after_start ->
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup} | Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(TestCase, Config)
  when TestCase =:= start_actor_returns_ok_pid;
       TestCase =:= actor_alive_after_start ->
    case ?config(sup, Config) of
        undefined -> ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    ok;
end_per_testcase(_TestCase, _Config) ->
    ok.

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

%% Criterion 2: an actor started through soma_actor_sup:start_actor/1 returns
%% {ok, Pid} with Pid a live process. Enters through the real supervisor entry,
%% no layer bypassed.
start_actor_returns_ok_pid(_Config) ->
    Opts = #{actor_id => <<"actor-1">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    true = is_pid(Pid),
    ok.

%% Criterion 3: immediately after start the actor pid passes is_process_alive/1.
%% Enters through the real supervisor entry, then checks liveness on the pid.
actor_alive_after_start(_Config) ->
    Opts = #{actor_id => <<"actor-1">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    true = is_process_alive(Pid),
    ok.
