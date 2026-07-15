%% @doc Dynamic supervisor for disposable delegate round workers.
-module(soma_delegate_round_sup).

-behaviour(supervisor).

-export([start_link/0, start_round/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_round(Opts) when is_map(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_delegate_round_worker,
                  start => {soma_delegate_round_worker, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
