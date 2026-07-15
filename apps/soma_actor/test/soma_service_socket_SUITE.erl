-module(soma_service_socket_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_socket_invoke_status_and_result_end_to_end/1,
         test_socket_disconnect_does_not_cancel_accepted_invocation/1,
         test_socket_duplicate_invoke_reuses_task_once/1,
         test_socket_watch_reconnect_resumes_after_cursor/1]).

all() ->
    [test_socket_invoke_status_and_result_end_to_end,
     test_socket_disconnect_does_not_cancel_accepted_invocation,
     test_socket_duplicate_invoke_reuses_task_once,
     test_socket_watch_reconnect_resumes_after_cursor].

init_per_testcase(
  test_socket_watch_reconnect_resumes_after_cursor, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [echo]}),
    TmpDir = make_tmp_dir(),
    LogPath = filename:join(TmpDir, "events.log"),
    ok = application:set_env(soma_runtime, event_store_log, LogPath),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started},
     {tmp_dir, TmpDir},
     {log_path, LogPath} | Config];
init_per_testcase(_TestCase, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [echo]}),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(_TestCase, Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    application:unset_env(soma_actor, service_policy),
    application:unset_env(soma_runtime, event_store_log),
    application:unload(soma_actor),
    maybe_del_tmp_dir(Config),
    ok.

%% RS.1d criterion 1: one real AF_UNIX service socket must adapt framed Lisp
%% lifecycle requests to the already-supervised service. The accepted invoke
%% runs the echo tool through soma_run/soma_tool_call, status exposes only the
%% bounded terminal projection, result preserves the exact inline output, and
%% no LLM worker participates anywhere in the path.
test_socket_invoke_status_and_result_end_to_end(_Config) ->
    ?assertEqual(
       {module, soma_service_socket},
       code:ensure_loaded(soma_service_socket)),
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    {module, soma_llm_call} = code:ensure_loaded(soma_llm_call),
    ok = start_llm_start_trace(),
    try
        RequestId = <<"socket-service-echo">>,
        Args = #{value => <<"exact inline socket output">>},
        ExpectedOutput = #{RequestId => Args},
        Invoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-echo\") "
              "(tool (name echo) "
              "(args (value \"exact inline socket output\"))))">>,

        Accepted = socket_request(Path, Invoke, invoke),
        #{task_id := TaskId,
          request_id := RequestId,
          status := accepted} = Accepted,

        Terminal = wait_for_socket_status(Path, TaskId, succeeded, 100),
        ?assertEqual(
           #{task_id => TaskId,
             request_id => RequestId,
             status => succeeded,
             summary =>
                 #{result_bytes =>
                       byte_size(
                         term_to_binary(
                           ExpectedOutput, [deterministic]))}},
           Terminal),

        ResultSource = lifecycle_source(result, TaskId),
        ?assertEqual(
           ExpectedOutput,
           socket_request(Path, ResultSource, result)),
        ?assertEqual([], stop_llm_start_trace())
    after
        clear_llm_start_trace(),
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 2: once the service accepts work, the socket connection has
%% no cancellation authority. Closing the invoking client while a production
%% sleep tool is still running must leave soma_service's run ownership intact.
test_socket_disconnect_does_not_cancel_accepted_invocation(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        RequestId = <<"socket-service-disconnect">>,
        Invoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-disconnect\") "
              "(tool (name sleep) (args (ms 300))) "
              "(scope \"sleep\"))">>,

        Accepted = socket_request(Path, Invoke, invoke),
        #{task_id := TaskId,
          request_id := RequestId,
          status := accepted} = Accepted,

        _Terminal = wait_for_socket_status(Path, TaskId, succeeded, 100),
        Events =
            soma_event_store:by_correlation(
              runtime_event_store(), TaskId),
        EventTypes = [maps:get(event_type, Event) || Event <- Events],
        ?assert(lists:member(<<"run.completed">>, EventTypes)),
        ?assertNot(lists:member(<<"run.cancelled">>, EventTypes))
    after
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 3: request-id deduplication remains owned by soma_service
%% across independent socket handlers. A byte-identical invoke on a new
%% connection must resolve to the original task without starting a second run.
test_socket_duplicate_invoke_reuses_task_once(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        RequestId = <<"socket-service-duplicate">>,
        Invoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-duplicate\") "
              "(tool (name sleep) (args (ms 300))) "
              "(scope \"sleep\"))">>,

        First = socket_request(Path, Invoke, invoke),
        #{task_id := TaskId,
          request_id := RequestId} = First,

        Duplicate = socket_request(Path, Invoke, invoke),
        #{task_id := DuplicateTaskId,
          request_id := RequestId} = Duplicate,
        ?assertEqual(TaskId, DuplicateTaskId),

        _Terminal = wait_for_socket_status(Path, TaskId, succeeded, 100),
        RunStarts =
            [Event
             || Event <-
                    soma_event_store:by_correlation(
                      runtime_event_store(), TaskId),
                maps:get(event_type, Event) =:= <<"run.started">>],
        ?assertEqual(1, length(RunStarts))
    after
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 4: a watch cursor belongs to the service task's durable
%% append-ordered trail, not to a connection handler. A second real AF_UNIX
%% connection must therefore resume at the first event after the first page.
test_socket_watch_reconnect_resumes_after_cursor(Config) ->
    Path = socket_path(),
    LogPath = proplists:get_value(log_path, Config),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        Invoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-watch-reconnect\") "
              "(tool (name echo) "
              "(args (value \"durable watch trail\"))))">>,

        #{task_id := TaskId} = socket_request(Path, Invoke, invoke),
        _Terminal = wait_for_socket_status(Path, TaskId, succeeded, 100),

        ?assertEqual(
           {ok, LogPath},
           application:get_env(soma_runtime, event_store_log)),
        ?assert(filelib:is_regular(LogPath)),
        DurableEvents =
            soma_event_store:by_correlation(
              runtime_event_store(), TaskId),
        DurableIds = [maps:get(event_id, Event)
                      || Event <- DurableEvents],
        PageLimit = 3,
        ?assert(length(DurableIds) >= PageLimit * 2),
        {ExpectedFirstIds, AfterFirstIds} =
            lists:split(PageLimit, DurableIds),
        {ExpectedSecondIds, _RemainingIds} =
            lists:split(PageLimit, AfterFirstIds),

        FirstResponse =
            socket_response(
              Path, watch_source(TaskId, undefined, PageLimit)),
        ?assertMatch(
           {service_reply, watch,
            #{events := [_ | _], cursor := FirstCursor}}
              when is_binary(FirstCursor),
           FirstResponse),
        {service_reply, watch,
         #{events := FirstEvents, cursor := FirstCursor}} =
            FirstResponse,
        FirstIds = [maps:get(event_id, Event)
                    || Event <- FirstEvents],
        ?assertEqual(ExpectedFirstIds, FirstIds),
        ?assertNotEqual(lists:last(FirstIds), FirstCursor),

        SecondResponse =
            socket_response(
              Path, watch_source(TaskId, FirstCursor, PageLimit)),
        ?assertMatch(
           {service_reply, watch,
            #{events := [_ | _], cursor := SecondCursor}}
              when is_binary(SecondCursor),
           SecondResponse),
        {service_reply, watch,
         #{events := SecondEvents}} = SecondResponse,
        SecondIds = [maps:get(event_id, Event)
                     || Event <- SecondEvents],
        ?assertEqual(ExpectedSecondIds, SecondIds),
        ?assertEqual(
           lists:nth(PageLimit + 1, DurableIds), hd(SecondIds)),
        ?assertNotEqual(lists:last(FirstIds), hd(SecondIds))
    after
        stop_listener(Listener, Path)
    end.

socket_request(Path, Source, Operation) ->
    {service_reply, Operation, Value} = socket_response(Path, Source),
    Value.

socket_response(Path, Source) ->
    {ok, Socket} =
        gen_tcp:connect(
          {local, Path}, 0,
          [binary, {packet, raw}, {active, false}], 5000),
    try
        ok = gen_tcp:send(Socket, frame(Source)),
        Reply = recv_frame(Socket),
        decode_service_response(Reply)
    after
        gen_tcp:close(Socket)
    end.

frame(Payload) ->
    <<(byte_size(Payload)):32/unsigned-big-integer, Payload/binary>>.

recv_frame(Socket) ->
    {ok, <<Length:32/unsigned-big-integer>>} =
        gen_tcp:recv(Socket, 4, 5000),
    {ok, Payload} = gen_tcp:recv(Socket, Length, 5000),
    Payload.

decode_service_response(Payload) ->
    case soma_lfe_reader:read_forms(Payload) of
        {ok,
         [[reply,
           ['api-version', <<"1">>],
           [operation, Operation],
           [value, EncodedValue]]]} ->
            {service_reply, Operation, decode_value(EncodedValue)};
        {ok,
         [[error,
           ['api-version', <<"1">>],
           [code, Code]]]} ->
            {service_error, Code}
    end.

decode_value([event | Pairs]) ->
    maps:from_list(
      [{decode_key(Key), decode_value(Value)}
       || [Key, Value] <- Pairs]);
decode_value([Key, Value]) when is_atom(Key); is_binary(Key) ->
    #{decode_key(Key) => decode_value(Value)};
decode_value(List) when is_list(List) ->
    case lists:all(fun is_pair/1, List) of
        true ->
            maps:from_list(
              [{decode_key(Key), decode_value(Value)}
               || [Key, Value] <- List]);
        false ->
            [decode_value(Value) || Value <- List]
    end;
decode_value(Value) ->
    Value.

is_pair([Key, _Value]) when is_atom(Key); is_binary(Key) -> true;
is_pair(_Other) -> false.

decode_key('task-id') -> task_id;
decode_key('request-id') -> request_id;
decode_key('result-bytes') -> result_bytes;
decode_key('event-id') -> event_id;
decode_key(Key) -> Key.

wait_for_socket_status(_Path, _TaskId, _Expected, 0) ->
    error(service_socket_task_did_not_reach_status);
wait_for_socket_status(Path, TaskId, Expected, Attempts) ->
    StatusSource = lifecycle_source(status, TaskId),
    case socket_request(Path, StatusSource, status) of
        #{status := Expected} = Task ->
            Task;
        #{status := Status}
          when Status =:= accepted; Status =:= running ->
            timer:sleep(10),
            wait_for_socket_status(
              Path, TaskId, Expected, Attempts - 1)
    end.

lifecycle_source(Operation, TaskId) ->
    iolist_to_binary(
      ["(", atom_to_list(Operation), " \"", TaskId, "\")"]).

watch_source(TaskId, undefined, Limit) ->
    iolist_to_binary(
      ["(watch \"", TaskId, "\" (limit ",
       integer_to_list(Limit), "))"]);
watch_source(TaskId, Cursor, Limit) ->
    iolist_to_binary(
      ["(watch \"", TaskId, "\" (cursor \"", Cursor,
       "\") (limit ", integer_to_list(Limit), "))"]).

start_llm_start_trace() ->
    1 = erlang:trace_pattern({soma_llm_call, start, 1}, true, [local]),
    _ = erlang:trace(all, true, [call, {tracer, self()}]),
    _ = erlang:trace(new, true, [call, {tracer, self()}]),
    ok.

stop_llm_start_trace() ->
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace(new, false, [call]),
    Ref = erlang:trace_delivered(all),
    collect_llm_start_calls(Ref, []).

collect_llm_start_calls(Ref, Calls) ->
    receive
        {trace_delivered, all, Ref} ->
            lists:reverse(Calls);
        {trace, _Pid, call, {soma_llm_call, start, Args}} ->
            collect_llm_start_calls(Ref, [Args | Calls])
    after 1000 ->
        error(llm_start_trace_not_delivered)
    end.

clear_llm_start_trace() ->
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace(new, false, [call]),
    _ = erlang:trace_pattern(
          {soma_llm_call, start, 1}, false, [local]),
    ok.

ensure_loaded(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

runtime_event_store() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, StorePid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    StorePid.

socket_path() ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_service_socket_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive]))
           ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.

make_tmp_dir() ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_service_socket_log_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])),
    Path = filename:join(Tmp, Name),
    ok = file:make_dir(Path),
    Path.

maybe_del_tmp_dir(Config) ->
    case proplists:get_value(tmp_dir, Config) of
        undefined -> ok;
        TmpDir -> file:del_dir_r(TmpDir)
    end.

stop_listener(Listener, Path) ->
    MRef = erlang:monitor(process, Listener),
    exit(Listener, shutdown),
    receive
        {'DOWN', MRef, process, Listener, _Reason} -> ok
    after 5000 ->
        exit(Listener, kill),
        error(service_socket_listener_did_not_stop)
    end,
    _ = file:delete(Path),
    ok.
