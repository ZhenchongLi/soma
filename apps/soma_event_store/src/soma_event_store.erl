-module(soma_event_store).

-behaviour(gen_server).

%% Public API
-export([start_link/0, append/2, all/1, by_run/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {events = [] :: [map()]}).

%%% Public API

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec append(pid(), map()) -> ok.
append(Pid, Event) when is_map(Event) ->
    gen_server:call(Pid, {append, Event}).

-spec all(pid()) -> [map()].
all(Pid) ->
    gen_server:call(Pid, all).

-spec by_run(pid(), term()) -> [map()].
by_run(Pid, RunId) ->
    gen_server:call(Pid, {by_run, RunId}).

%%% gen_server callbacks

init([]) ->
    {ok, #state{}}.

handle_call({append, Event}, _From, State = #state{events = Events}) ->
    {reply, ok, State#state{events = [Event | Events]}};
handle_call(all, _From, State = #state{events = Events}) ->
    {reply, lists:reverse(Events), State};
handle_call({by_run, RunId}, _From, State = #state{events = Events}) ->
    Matching = [E || E <- lists:reverse(Events), maps:get(run_id, E, undefined) =:= RunId],
    {reply, Matching, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
