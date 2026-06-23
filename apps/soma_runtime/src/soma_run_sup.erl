%% @doc Supervisor for `soma_run' processes. Runs are started on demand,
%% one child spec, so it uses `simple_one_for_one'.
-module(soma_run_sup).

-behaviour(supervisor).

-export([start_link/0, start_run/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Start one `soma_run' child on demand. `Opts' carries the run_id and steps.
start_run(Opts) when is_map(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_run,
                  start => {soma_run, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
