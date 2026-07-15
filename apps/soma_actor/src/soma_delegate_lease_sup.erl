%% @doc Dynamic supervisor for temporary task-scoped delegate lease guards.
-module(soma_delegate_lease_sup).

-behaviour(supervisor).

-export([start_link/0, start_guard/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_guard(Opts) when is_map(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_delegate_lease_guard,
                  start => {soma_delegate_lease_guard, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
