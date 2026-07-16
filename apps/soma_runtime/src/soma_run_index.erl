%% @doc Live run-id ownership index.
%%
%% Every `soma_run' claims its RunId here during init, before journalling or
%% starting a tool.  The claim is atomic and remains visible when
%% `soma_run_sup' changes generation, so a suspended child from the old
%% supervisor cannot overlap a resumed child under the new supervisor.
%%
%% The index is a supervised server rather than an ETS/process-dictionary
%% shortcut.  It monitors every owner and releases the id only after the owner
%% is actually dead.
-module(soma_run_index).

-behaviour(gen_server).

-export([start_link/0, claim/2, claim/3, lookup/1, lookup/2,
         lookup_owner/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(CLAIM_TIMEOUT_MS, 1000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

claim(RunId, RunPid) when is_pid(RunPid) ->
    claim(RunId, RunPid, undefined).

claim(RunId, RunPid, RunSupervisor) when is_pid(RunPid) ->
    gen_server:call(?MODULE,
                    {claim, RunId, RunPid, RunSupervisor},
                    ?CLAIM_TIMEOUT_MS).

lookup(RunId) ->
    gen_server:call(?MODULE, {lookup, RunId}).

lookup(RunId, Timeout) ->
    gen_server:call(?MODULE, {lookup, RunId}, Timeout).

lookup_owner(RunId, Timeout) ->
    gen_server:call(?MODULE, {lookup_owner, RunId}, Timeout).

init([]) ->
    %% A killed supervisor can leave a trap-exit `soma_run' scheduled or
    %% sys-suspended after the supervisor name has already been reused.  On
    %% every index generation, kill those pre-existing owners before opening
    %% the new claim table.  `exit(Pid, kill)' is intentional: it cannot be
    %% deferred by a suspended gen_statem, and the run/worker link tears down
    %% any active invocation. New run init calls are queued behind this init
    %% and therefore cannot cross the fence.
    case fence_preexisting_runs() of
        ok -> {ok, #{runs => #{}, monitors => #{}}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({claim, RunId, RunPid, RunSupervisor}, _From,
            #{runs := Runs, monitors := Monitors} = State) ->
    case maps:find(RunId, Runs) of
        {ok, #{pid := RunPid}} ->
            {reply, ok, State};
        {ok, #{pid := ExistingPid}} ->
            case is_process_alive(ExistingPid) of
                true ->
                    {reply, {error, {run_id_in_use, ExistingPid}}, State};
                false ->
                    {reply, ok,
                     replace_stale_claim(
                       RunId, RunPid, RunSupervisor, State)}
            end;
        error ->
            MRef = erlang:monitor(process, RunPid),
            {SupMRef, Monitors1} = monitor_supervisor(
                                     RunId, RunPid, RunSupervisor,
                                     Monitors),
            Entry = #{pid => RunPid, mref => MRef,
                      supervisor => RunSupervisor,
                      supervisor_mref => SupMRef},
            {reply, ok,
             State#{runs := Runs#{RunId => Entry},
                    monitors := Monitors1#{MRef =>
                                               #{kind => run,
                                                 run_id => RunId,
                                                 pid => RunPid}}}}
    end;
handle_call({lookup, RunId}, _From, #{runs := Runs} = State) ->
    case maps:find(RunId, Runs) of
        {ok, #{pid := RunPid}} ->
            case is_process_alive(RunPid) of
                true -> {reply, {ok, RunPid}, State};
                false -> {reply, {error, not_found}, drop_run(RunId, State)}
            end;
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call({lookup_owner, RunId}, _From, #{runs := Runs} = State) ->
    case maps:find(RunId, Runs) of
        {ok, #{pid := RunPid, supervisor := RunSupervisor}} ->
            case is_process_alive(RunPid) of
                true -> {reply, {ok, RunPid, RunSupervisor}, State};
                false -> {reply, {error, not_found}, drop_run(RunId, State)}
            end;
        error ->
            {reply, {error, not_found}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, DownPid, _Reason},
            #{monitors := Monitors} = State) ->
    case maps:find(MRef, Monitors) of
        {ok, #{kind := run, run_id := RunId, pid := DownPid}} ->
            {noreply, drop_run(RunId, State)};
        {ok, #{kind := supervisor, run_id := RunId,
               run_pid := RunPid, supervisor := DownPid}} ->
            %% A run traps linked exits so it can classify worker crashes. Its
            %% supervisor generation ending must nevertheless be immediate:
            %% an untrappable kill prevents a sys-suspended child from becoming
            %% an unsupervised orphan under the replacement generation.
            exit(RunPid, kill),
            {noreply, clear_supervisor_monitor(RunId, MRef, State)};
        _Stale ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

replace_stale_claim(RunId, RunPid, RunSupervisor,
                    #{runs := Runs, monitors := Monitors} = State) ->
    #{mref := OldMRef, supervisor_mref := OldSupMRef} =
        maps:get(RunId, Runs),
    erlang:demonitor(OldMRef, [flush]),
    demonitor_optional(OldSupMRef),
    MRef = erlang:monitor(process, RunPid),
    Monitors0 = maps:remove(OldSupMRef, maps:remove(OldMRef, Monitors)),
    {SupMRef, Monitors1} = monitor_supervisor(
                             RunId, RunPid, RunSupervisor, Monitors0),
    Entry = #{pid => RunPid, mref => MRef,
              supervisor => RunSupervisor,
              supervisor_mref => SupMRef},
    State#{runs := Runs#{RunId => Entry},
           monitors := Monitors1#{MRef => #{kind => run,
                                            run_id => RunId,
                                            pid => RunPid}}}.

drop_run(RunId, #{runs := Runs, monitors := Monitors} = State) ->
    case maps:take(RunId, Runs) of
        {#{mref := MRef, supervisor_mref := SupMRef}, RemainingRuns} ->
            erlang:demonitor(MRef, [flush]),
            demonitor_optional(SupMRef),
            State#{runs := RemainingRuns,
                   monitors := maps:remove(
                                 SupMRef, maps:remove(MRef, Monitors))};
        error ->
            State
    end.

monitor_supervisor(RunId, RunPid, RunSupervisor, Monitors)
  when is_pid(RunSupervisor) ->
    SupMRef = erlang:monitor(process, RunSupervisor),
    {SupMRef,
     Monitors#{SupMRef => #{kind => supervisor,
                            run_id => RunId,
                            run_pid => RunPid,
                            supervisor => RunSupervisor}}};
monitor_supervisor(_RunId, _RunPid, _RunSupervisor, Monitors) ->
    {undefined, Monitors}.

clear_supervisor_monitor(
  RunId, SupMRef, #{runs := Runs, monitors := Monitors} = State) ->
    Runs1 = case maps:find(RunId, Runs) of
                {ok, Entry} ->
                    Runs#{RunId => Entry#{supervisor_mref => undefined}};
                error -> Runs
            end,
    State#{runs := Runs1, monitors := maps:remove(SupMRef, Monitors)}.

demonitor_optional(MRef) when is_reference(MRef) ->
    erlang:demonitor(MRef, [flush]),
    ok;
demonitor_optional(_MRef) ->
    ok.

fence_preexisting_runs() ->
    RunPids = [Pid || Pid <- processes(), Pid =/= self(), is_soma_run(Pid)],
    Pending = maps:from_list(
                [begin
                     MRef = erlang:monitor(process, Pid),
                     exit(Pid, kill),
                     {MRef, Pid}
                 end || Pid <- RunPids]),
    await_fenced_runs(Pending,
                      erlang:monotonic_time(millisecond) +
                          ?CLAIM_TIMEOUT_MS).

is_soma_run(Pid) ->
    try proc_lib:initial_call(Pid) of
        {soma_run, init, _Args} -> true;
        _Other -> false
    catch
        _:_ -> false
    end.

await_fenced_runs(Pending, _Deadline) when map_size(Pending) =:= 0 ->
    ok;
await_fenced_runs(Pending, Deadline) ->
    receive
        {'DOWN', MRef, process, _Pid, _Reason}
          when is_map_key(MRef, Pending) ->
            await_fenced_runs(maps:remove(MRef, Pending), Deadline)
    after erlang:max(0, Deadline - erlang:monotonic_time(millisecond)) ->
            maps:foreach(
              fun(MRef, _Pid) -> erlang:demonitor(MRef, [flush]) end,
              Pending),
            {error, {run_fence_timeout, map_size(Pending)}}
    end.
