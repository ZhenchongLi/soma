-module(soma_event_store).

-behaviour(gen_server).

%% Public API
-export([start_link/0, start_link/1, append/2, all/1, by_run/2, by_session/2,
         by_correlation/2, interrupted_runs/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {events = [] :: [map()], log = undefined :: term()}).

%%% Public API

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec start_link(map()) -> {ok, pid()}.
start_link(#{log := Path}) ->
    gen_server:start_link(?MODULE, #{log => Path}, []).

-spec append(pid(), map()) -> ok.
append(Pid, Event) when is_map(Event) ->
    gen_server:call(Pid, {append, Event}).

-spec all(pid()) -> [map()].
all(Pid) ->
    gen_server:call(Pid, all).

-spec by_run(pid(), term()) -> [map()].
by_run(Pid, RunId) ->
    gen_server:call(Pid, {by_run, RunId}).

-spec by_session(pid(), term()) -> [map()].
by_session(Pid, SessionId) ->
    gen_server:call(Pid, {by_session, SessionId}).

-spec by_correlation(pid(), term()) -> [map()].
by_correlation(Pid, CorrelationId) ->
    gen_server:call(Pid, {by_correlation, CorrelationId}).

-spec interrupted_runs(pid()) -> [term()].
interrupted_runs(Pid) ->
    gen_server:call(Pid, interrupted_runs).

%%% gen_server callbacks

init([]) ->
    {ok, #state{}};
init(#{log := Path}) ->
    Log = {?MODULE, Path},
    case disk_log:open([{name, Log},
                        {file, Path},
                        {type, halt}]) of
        {ok, Log} -> ok;
        {repaired, Log, _Recovered, _BadBytes} -> ok
    end,
    Events = replay_log(Log),
    {ok, #state{events = Events, log = Log}}.

%% Read every term the log holds, in append (oldest-first) order, and build the
%% in-memory index in the same internal order an equivalent sequence of
%% append/2 calls would produce (newest first). all/1 reverses it back to
%% append order. The index is a rebuildable cache; the log is the source of
%% truth.
replay_log(Log) ->
    replay_log(Log, start, []).

replay_log(Log, Cont, Acc) ->
    %% Read a single term per chunk. A corrupt tail (a half-written term left by
    %% an unclean shutdown) makes disk_log:chunk/3 return
    %% {error, {corrupt_log_file, _}} for the chunk that spans the bad bytes;
    %% reading one term at a time keeps every intact term that precedes the
    %% corrupt tail, where a larger chunk would discard the whole block. Replay
    %% is linear in the log and runs once at boot, so the per-term granularity is
    %% acceptable here.
    case disk_log:chunk(Log, Cont, 1) of
        eof ->
            Acc;
        %% Corrupt tail: treat it as end-of-log. Keep every intact term read so
        %% far and finish init/1 cleanly — a damaged tail costs the last partial
        %% event, not the boot.
        {error, {corrupt_log_file, _}} ->
            Acc;
        {NextCont, Terms, _BadBytes} ->
            replay_log(Log, NextCont, prepend_all(Terms, Acc));
        {NextCont, Terms} ->
            replay_log(Log, NextCont, prepend_all(Terms, Acc))
    end.

prepend_all(Terms, Acc) ->
    lists:foldl(fun(Term, A) -> [Term | A] end, Acc, Terms).

handle_call({append, Event}, _From, State = #state{events = Events, log = Log}) ->
    Normalized = normalize(Event),
    ok = log_event(Log, Normalized),
    {reply, ok, State#state{events = [Normalized | Events]}};
handle_call(all, _From, State = #state{events = Events}) ->
    {reply, lists:reverse(Events), State};
handle_call({by_run, RunId}, _From, State = #state{events = Events}) ->
    Matching = [E || E <- lists:reverse(Events), maps:get(run_id, E, undefined) =:= RunId],
    {reply, Matching, State};
handle_call({by_session, SessionId}, _From, State = #state{events = Events}) ->
    Matching = [E || E <- lists:reverse(Events), maps:get(session_id, E, undefined) =:= SessionId],
    {reply, Matching, State};
handle_call({by_correlation, CorrelationId}, _From, State = #state{events = Events}) ->
    Matching = [E || E <- lists:reverse(Events), maps:get(correlation_id, E, undefined) =:= CorrelationId],
    {reply, Matching, State};
handle_call(interrupted_runs, _From, State = #state{events = Events}) ->
    RunIds = interrupted_run_ids(lists:reverse(Events)),
    {reply, RunIds, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

-define(MANDATORY_KEYS,
        [event_id, timestamp, session_id, run_id, step_id, tool_call_id,
         event_type, payload]).

normalize(Event) ->
    WithId = case maps:is_key(event_id, Event) of
                 true -> Event;
                 false -> Event#{event_id => make_event_id()}
             end,
    WithTimestamp = case maps:get(timestamp, WithId, undefined) of
                        undefined -> WithId#{timestamp => erlang:system_time(nanosecond)};
                        _ -> WithId
                    end,
    lists:foldl(fun(Key, Acc) ->
                        case maps:is_key(Key, Acc) of
                            true -> Acc;
                            false -> Acc#{Key => undefined}
                        end
                end,
                WithTimestamp,
                ?MANDATORY_KEYS).

make_event_id() ->
    list_to_binary(erlang:ref_to_list(make_ref())).

log_event(undefined, _Event) ->
    ok;
log_event(Log, Event) ->
    disk_log:log(Log, Event).

interrupted_run_ids(Events) ->
    Started = started_run_ids(Events),
    Terminal = terminal_run_ids(Events),
    [RunId || RunId <- Started, not lists:member(RunId, Terminal)].

started_run_ids(Events) ->
    lists:reverse(lists:foldl(fun maybe_add_started_run/2, [], Events)).

maybe_add_started_run(#{event_type := <<"run.started">>, run_id := RunId}, Acc)
  when RunId =/= undefined ->
    add_once(RunId, Acc);
maybe_add_started_run(_Event, Acc) ->
    Acc.

terminal_run_ids(Events) ->
    lists:foldl(fun maybe_add_terminal_run/2, [], Events).

maybe_add_terminal_run(#{event_type := Type, run_id := RunId}, Acc)
  when RunId =/= undefined ->
    case is_terminal_run_event(Type) of
        true -> add_once(RunId, Acc);
        false -> Acc
    end;
maybe_add_terminal_run(_Event, Acc) ->
    Acc.

is_terminal_run_event(<<"run.completed">>) -> true;
is_terminal_run_event(<<"run.failed">>) -> true;
is_terminal_run_event(<<"run.timeout">>) -> true;
is_terminal_run_event(<<"run.cancelled">>) -> true;
is_terminal_run_event(_) -> false.

add_once(Value, Values) ->
    case lists:member(Value, Values) of
        true -> Values;
        false -> [Value | Values]
    end.
