%% @doc Supervisor for `soma_run' processes. Runs are started on demand,
%% one child spec, so it uses `simple_one_for_one'.
-module(soma_run_sup).

-behaviour(supervisor).

-export([start_link/0, start_run/1, find_run/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Start one `soma_run' child on demand. `Opts' carries the run_id and steps.
start_run(Opts) when is_map(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).

%% Find the live child that owns `RunId'. Dynamic run children have no stable
%% supervisor child id, so ask each run for its bounded identity. A child may
%% terminate between `which_children/1' and the call; that race is a miss, not
%% a supervisor failure.
find_run(RunId) ->
    find_run(RunId, supervisor:which_children(?MODULE)).

find_run(_RunId, []) ->
    {error, not_found};
find_run(RunId, [{_ChildId, Pid, worker, [soma_run]} | Rest])
  when is_pid(Pid) ->
    case run_identity(Pid) of
        {ok, #{run_id := RunId}} ->
            {ok, Pid};
        _ ->
            find_run(RunId, Rest)
    end;
find_run(RunId, [_Other | Rest]) ->
    find_run(RunId, Rest).

run_identity(Pid) ->
    try soma_run:identity(Pid) of
        Identity -> Identity
    catch
        exit:_Reason -> {error, not_found}
    end.

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_run,
                  start => {soma_run, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
