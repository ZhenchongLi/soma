%% @doc Actor stable-name registry proofs.
-module(soma_actor_registry_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([lookup_registered_actor_returns_pid/1]).

all() ->
    [lookup_registered_actor_returns_pid].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(_TestCase, _Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    ok.

%% Criterion 1: a named actor started through the production supervisor registers
%% its stable name, and a production registry lookup returns that live actor pid.
lookup_registered_actor_returns_pid(_Config) ->
    StableName = <<"actor-registry-lookup">>,
    Opts = #{actor_id => <<"actor-registry-lookup-id">>,
             stable_name => StableName,
             model_config => #{},
             tool_policy => #{}},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    {ok, ActorPid} = soma_actor_registry:lookup(StableName),
    true = is_process_alive(ActorPid),
    ok.
