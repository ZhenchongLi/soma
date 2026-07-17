%% @doc Supervisor for `soma_run' processes. Runs are started on demand,
%% one child spec, so it uses `simple_one_for_one'.  Exact RunId lookup is
%% delegated to `soma_run_index': terminal history size and unrelated suspended
%% children therefore do not affect recovery latency.
-module(soma_run_sup).

-behaviour(supervisor).

-export([start_link/0, start_run/1, start_run/2, find_run/1, find_run/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Preserve the original unbounded public start path for existing owners.
start_run(Opts) when is_map(Opts) ->
    case whereis(?MODULE) of
        undefined -> {error, {run_supervisor_unavailable, undefined}};
        SupPid ->
            supervisor:start_child(
              SupPid, [Opts#{run_supervisor_generation => SupPid}])
    end.

%% Recovery owners use one finite end-to-end start attempt. The helper is
%% linked to its caller so it cannot outlive a killed registry. On timeout the
%% caller unlinks before killing it; a start whose acknowledgement was lost may
%% still finish in the supervisor, but the atomic run-index claim makes the
%% next recovery pass adopt that child instead of starting a duplicate.
start_run(Opts, Timeout)
  when is_map(Opts), is_integer(Timeout), Timeout >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            {error, {run_supervisor_unavailable, undefined}};
        SupPid ->
            bounded_start(SupPid, Opts, Timeout)
    end.

find_run(RunId) ->
    %% Preserve the original current-supervisor scan and unbounded identity
    %% semantics for existing runtime-service callers. CLI recovery opts into
    %% the indexed finite /2 path, whose cross-generation fencing is new.
    find_run_legacy(RunId, supervisor:which_children(?MODULE)).

find_run(RunId, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    try soma_run_index:lookup_owner(RunId, Timeout) of
        {ok, RunPid, RunSupervisor} ->
            case whereis(?MODULE) of
                RunSupervisor -> {ok, RunPid};
                Current ->
                    {error, {stale_run_generation, RunPid,
                             RunSupervisor, Current}}
            end;
        Other -> Other
    catch
        exit:{timeout, _} -> {error, {run_index_unresponsive,
                                     whereis(soma_run_index)}};
        exit:Reason -> {error, {run_index_unavailable, Reason}}
    end;
find_run(RunId, infinity) ->
    find_run(RunId).

find_run_legacy(_RunId, []) ->
    {error, not_found};
find_run_legacy(RunId,
                [{_ChildId, Pid, worker, [soma_run]} | Rest])
  when is_pid(Pid) ->
    Identity = try soma_run:identity(Pid) of
                   Result -> Result
               catch
                   exit:_Reason -> {error, not_found}
               end,
    case Identity of
        {ok, #{run_id := RunId}} -> {ok, Pid};
        _ -> find_run_legacy(RunId, Rest)
    end;
find_run_legacy(RunId, [_Other | Rest]) ->
    find_run_legacy(RunId, Rest).

bounded_start(SupPid, Opts, Timeout) ->
    Parent = self(),
    Tag = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    {Helper, MRef} =
        spawn_opt(
          fun() ->
                  %% A bounded caller can lose the start_child acknowledgement
                  %% while the request remains queued in the supervisor. Such a
                  %% late child is always paused and carries the same absolute
                  %% lease: without an observed acknowledgement and activation
                  %% it exits before journalling or invoking a tool.
                  ChildOpts = Opts#{run_supervisor_generation => SupPid,
                                    start_paused => true,
                                    start_lease_deadline_ms => Deadline},
                  Result = try supervisor:start_child(SupPid, [ChildOpts]) of
                               Started -> normalize_start_result(Started)
                           catch
                               Class:Reason ->
                                   {error,
                                    {run_supervisor_unavailable,
                                     {Class, Reason}}}
                           end,
                  Parent ! {Tag, self(), Result}
          end, [link, monitor]),
    receive
        {Tag, Helper, Result} ->
            unlink(Helper),
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Helper, Reason} ->
            unlink(Helper),
            {error, {run_supervisor_unavailable, Reason}}
    after erlang:max(0, Deadline -
                           erlang:monotonic_time(millisecond)) ->
            unlink(Helper),
            exit(Helper, kill),
            erlang:demonitor(MRef, [flush]),
            flush_start_reply(Tag),
            {error, {run_supervisor_unresponsive, SupPid}}
    end.

normalize_start_result({ok, undefined}) ->
    {error, start_lease_expired};
normalize_start_result({ok, undefined, _Info}) ->
    {error, start_lease_expired};
normalize_start_result(Result) ->
    Result.

flush_start_reply(Tag) ->
    receive
        {Tag, _Helper, _Result} -> ok
    after 0 ->
            ok
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
