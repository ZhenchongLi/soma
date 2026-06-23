%% @doc The top-level supervisor. Boots the four core children in order:
%% `soma_event_store', `soma_tool_registry', `soma_session_sup', `soma_run_sup'.
-module(soma_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 1,
                 period => 5},
    Children =
        [#{id => soma_event_store,
           start => {soma_event_store, start_link, []},
           type => worker},
         #{id => soma_tool_registry,
           start => {soma_tool_registry, start_link, []},
           type => worker},
         #{id => soma_session_sup,
           start => {soma_session_sup, start_link, []},
           type => supervisor},
         #{id => soma_run_sup,
           start => {soma_run_sup, start_link, []},
           type => supervisor}],
    {ok, {SupFlags, Children}}.
