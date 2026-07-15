%% @doc Dynamic supervisor for per-task delegate coordinators.
-module(soma_delegate_coordinator_sup).

-behaviour(supervisor).

-export([start_link/0, start_coordinator/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_coordinator(Opts) when is_map(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_delegate_coordinator,
                  start => {soma_delegate_coordinator, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
