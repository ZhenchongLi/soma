%% @doc Root supervisor for the `soma_actor' application. Actor instances are
%% started on demand, one child spec, so it uses `simple_one_for_one'. The
%% dynamic child forward-references `soma_actor', the worker module a later
%% slice adds; a `simple_one_for_one' child spec is only resolved on
%% `start_child', which this slice never calls.
-module(soma_actor_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_actor,
                  start => {soma_actor, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
