%% @doc Long-lived session process. A session owns a `session_id' and accepts
%% run requests; it never executes tool logic itself. v0.1 happy path: starting
%% a session assigns a fresh `session_id' that `get_status/1' reports.
-module(soma_agent_session).

-behaviour(gen_server).

-export([start_link/1, get_status/1, start_run/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% `runs' tracks each run the session has started: `RunId => #{pid, status}'.
%% A run reports `{run_completed, RunId, Result}' on reaching a terminal state;
%% the session records the status and survives, never linking on a normal exit.
-record(state, {session_id, event_store, runs = #{}}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

get_status(Pid) ->
    gen_server:call(Pid, get_status).

%% Submit a run request. Returns `{ok, RunId}'; the session generates the
%% run_id, starts a `soma_run' under `soma_run_sup', and tracks it active.
start_run(Pid, Steps) when is_list(Steps) ->
    gen_server:call(Pid, {start_run, Steps}).

init(_Opts) ->
    SessionId = new_session_id(),
    StorePid = event_store_pid(),
    soma_event_store:append(StorePid,
                            #{session_id => SessionId,
                              event_type => <<"session.started">>}),
    {ok, #state{session_id = SessionId, event_store = StorePid}}.

handle_call(get_status, _From, State) ->
    RunStatuses = maps:map(fun(_RunId, Run) -> maps:get(status, Run) end,
                           State#state.runs),
    {reply, #{session_id => State#state.session_id, runs => RunStatuses}, State};
handle_call({start_run, Steps}, _From, State) ->
    RunId = new_run_id(),
    soma_event_store:append(State#state.event_store,
                            #{session_id => State#state.session_id,
                              run_id => RunId,
                              event_type => <<"run.accepted">>}),
    {ok, RunPid} = soma_run_sup:start_run(#{run_id => RunId,
                                            session_id => State#state.session_id,
                                            session_pid => self(),
                                            event_store => State#state.event_store,
                                            steps => Steps}),
    Runs = maps:put(RunId, #{pid => RunPid, status => running},
                    State#state.runs),
    {reply, {ok, RunId}, State#state{runs = Runs}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% A run reached a terminal state and reported back; record it as completed.
%% The session survives the run finishing -- it learns the outcome from this
%% message, not from a link signal.
handle_info({run_completed, RunId, _Result}, State) ->
    Runs = case maps:find(RunId, State#state.runs) of
               {ok, Run} ->
                   maps:put(RunId, Run#{status => completed}, State#state.runs);
               error ->
                   State#state.runs
           end,
    {noreply, State#state{runs = Runs}};
handle_info(_Msg, State) ->
    {noreply, State}.

new_session_id() ->
    list_to_binary("sess-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

new_run_id() ->
    list_to_binary("run-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

%% Locate the running event store pid from the booted supervision tree.
event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
