%% @doc Long-lived session process. A session owns a `session_id' and accepts
%% run requests; it never executes tool logic itself. v0.1 happy path: starting
%% a session assigns a fresh `session_id' that `get_status/1' reports.
-module(soma_agent_session).

-behaviour(gen_server).

-export([start_link/1, get_status/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {session_id, event_store}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

get_status(Pid) ->
    gen_server:call(Pid, get_status).

init(_Opts) ->
    SessionId = new_session_id(),
    StorePid = event_store_pid(),
    soma_event_store:append(StorePid,
                            #{session_id => SessionId,
                              event_type => <<"session.started">>}),
    {ok, #state{session_id = SessionId, event_store = StorePid}}.

handle_call(get_status, _From, State) ->
    {reply, #{session_id => State#state.session_id}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

new_session_id() ->
    list_to_binary("sess-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

%% Locate the running event store pid from the booted supervision tree.
event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
