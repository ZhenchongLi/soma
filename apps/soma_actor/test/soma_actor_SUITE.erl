-module(soma_actor_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([actor_is_gen_statem_with_callbacks/1]).
-export([start_actor_returns_ok_pid/1]).
-export([actor_alive_after_start/1]).
-export([actor_starts_idle/1]).
-export([actor_state_holds_config/1]).

all() ->
    [actor_is_gen_statem_with_callbacks,
     start_actor_returns_ok_pid,
     actor_alive_after_start,
     actor_starts_idle,
     actor_state_holds_config].

init_per_testcase(TestCase, Config)
  when TestCase =:= start_actor_returns_ok_pid;
       TestCase =:= actor_alive_after_start;
       TestCase =:= actor_starts_idle;
       TestCase =:= actor_state_holds_config ->
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup} | Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(TestCase, Config)
  when TestCase =:= start_actor_returns_ok_pid;
       TestCase =:= actor_alive_after_start;
       TestCase =:= actor_starts_idle;
       TestCase =:= actor_state_holds_config ->
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

%% Criterion 4: immediately after start the actor is in state idle.
%% Enters through the real supervisor entry, then reads the state name via
%% sys:get_state/1, which on a state_functions gen_statem returns {StateName, Data}.
actor_starts_idle(_Config) ->
    Opts = #{actor_id => <<"actor-1">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    {idle, _Data} = sys:get_state(Pid),
    ok.

%% Criterion 5: the actor's state data holds the actor_id, model_config, and
%% tool_policy passed in Opts, readable through sys:get_state/1. The data record
%% lays actor_id, model_config, tool_policy out as the first three fields (record
%% positions 2, 3, 4 after the record tag), so the test pulls those fields by
%% position rather than binding the whole tuple — a later slice that appends
%% fields will not break this.
actor_state_holds_config(_Config) ->
    ActorId = <<"actor-cfg">>,
    ModelConfig = #{model => <<"test-model">>},
    ToolPolicy = #{allow => [echo]},
    Opts = #{actor_id => ActorId,
             model_config => ModelConfig,
             tool_policy => ToolPolicy},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    {idle, Data} = sys:get_state(Pid),
    ActorId = element(2, Data),
    ModelConfig = element(3, Data),
    ToolPolicy = element(4, Data),
    ok.
