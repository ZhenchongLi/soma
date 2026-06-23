%% @doc Supervisor for `soma_agent_session' processes. Sessions are started
%% on demand, one child spec, so it uses `simple_one_for_one'.
-module(soma_session_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_agent_session,
                  start => {soma_agent_session, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
