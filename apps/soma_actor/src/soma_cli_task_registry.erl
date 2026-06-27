%% @doc In-memory live-task registry for CLI daemon task ownership.
-module(soma_cli_task_registry).

-behaviour(gen_server).
-compile({no_auto_import, [register/2]}).

-export([start_link/0, register/2, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(TaskId, Task) when is_map(Task) ->
    gen_server:call(?MODULE, {register, TaskId, Task}).

lookup(TaskId) ->
    gen_server:call(?MODULE, {lookup, TaskId}).

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
    {reply, Reply, State}.

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
