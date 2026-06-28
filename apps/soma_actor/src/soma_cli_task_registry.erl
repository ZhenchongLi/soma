%% @doc In-memory live-task registry for CLI daemon task ownership.
-module(soma_cli_task_registry).

-behaviour(gen_server).
-compile({no_auto_import, [register/2]}).

-export([start_link/0, register/2, lookup/1, start_detached_run/5,
         cancel/1, cancel_all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(TaskId, Task) when is_map(Task) ->
    gen_server:call(?MODULE, {register, TaskId, Task}).

lookup(TaskId) ->
    gen_server:call(?MODULE, {lookup, TaskId}).

start_detached_run(TaskId, CorrId, RunId, Steps, Store) ->
    gen_server:call(?MODULE,
                    {start_detached_run, TaskId, CorrId, RunId, Steps, Store}).

cancel(TaskId) ->
    gen_server:call(?MODULE, {cancel, TaskId}).

cancel_all() ->
    gen_server:call(?MODULE, cancel_all).

init([]) ->
    {ok, #{tasks => #{}, runs => #{}}}.

handle_call({register, TaskId, Task}, _From,
            #{tasks := Tasks, runs := Runs} = State) ->
    Runs1 = case maps:find(run_id, Task) of
                {ok, RunId} -> Runs#{RunId => TaskId};
                error -> Runs
            end,
    {reply, ok, State#{tasks := Tasks#{TaskId => Task}, runs := Runs1}};
handle_call({lookup, TaskId}, _From, #{tasks := Tasks} = State) ->
    Reply = case maps:find(TaskId, Tasks) of
                {ok, Task} -> {ok, Task};
                error -> {error, not_found}
            end,
    {reply, Reply, State};
handle_call({cancel, TaskId}, _From, #{tasks := Tasks} = State) ->
    Reply = case maps:find(TaskId, Tasks) of
                {ok, #{status := running, pid := RunPid}} ->
                    RunPid ! cancel,
                    ok;
                {ok, #{status := Status}} ->
                    {error, {not_running, Status}};
                error ->
                    {error, not_found}
            end,
    {reply, Reply, State};
handle_call(cancel_all, _From, #{tasks := Tasks} = State) ->
    %% Send the bare `cancel' to every running run's pid -- the same lever
    %% `cancel/1' drives -- so a `(stop)' drains in-flight detached runs. Each
    %% `soma_run' tears down its worker and emits `run.cancelled' itself.
    _ = maps:foreach(
          fun(_TaskId, #{status := running, pid := RunPid}) ->
                  RunPid ! cancel;
             (_TaskId, _Task) ->
                  ok
          end, Tasks),
    {reply, ok, State};
handle_call({start_detached_run, TaskId, CorrId, RunId, Steps, Store}, _From,
            #{tasks := Tasks, runs := Runs} = State) ->
    {ok, RunPid} = soma_run_sup:start_run(
                     #{run_id => RunId,
                       session_id => TaskId,
                       session_pid => self(),
                       event_store => Store,
                       steps => Steps,
                       correlation_id => CorrId}),
    Task = #{pid => RunPid,
             status => running,
             correlation_id => CorrId,
             run_id => RunId},
    State1 = State#{tasks := Tasks#{TaskId => Task},
                    runs := Runs#{RunId => TaskId}},
    Reply = {ok, #{task_id => TaskId,
                   correlation_id => CorrId,
                   run_id => RunId,
                   pid => RunPid}},
    {reply, Reply, State1}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({run_completed, RunId, _Outputs}, State) ->
    {noreply, update_terminal_status(RunId, completed, State)};
handle_info({run_failed, RunId, _Reason}, State) ->
    {noreply, update_terminal_status(RunId, failed, State)};
handle_info({run_timeout, RunId}, State) ->
    {noreply, update_terminal_status(RunId, timeout, State)};
handle_info({run_cancelled, RunId}, State) ->
    {noreply, update_terminal_status(RunId, cancelled, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

update_terminal_status(RunId, Status,
                       #{tasks := Tasks, runs := Runs} = State) ->
    case maps:find(RunId, Runs) of
        {ok, TaskId} ->
            case maps:find(TaskId, Tasks) of
                {ok, Task} ->
                    State#{tasks := Tasks#{TaskId => Task#{status => Status}}};
                error ->
                    State
            end;
        error ->
            State
    end.
