-module(soma_service_socket_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_socket_invoke_status_and_result_end_to_end/1,
         test_socket_disconnect_does_not_cancel_accepted_invocation/1,
         test_socket_duplicate_invoke_reuses_task_once/1,
         test_socket_watch_reconnect_resumes_after_cursor/1,
         test_socket_cancel_is_repeatable_after_cli_process_exit/1,
         test_socket_version_and_operation_errors_are_typed/1]).

all() ->
    [test_socket_invoke_status_and_result_end_to_end,
     test_socket_disconnect_does_not_cancel_accepted_invocation,
     test_socket_duplicate_invoke_reuses_task_once,
     test_socket_watch_reconnect_resumes_after_cursor,
     test_socket_cancel_is_repeatable_after_cli_process_exit,
     test_socket_version_and_operation_errors_are_typed].

init_per_testcase(
  TestCase, Config)
  when TestCase =:= test_socket_watch_reconnect_resumes_after_cursor;
       TestCase =:= test_socket_cancel_is_repeatable_after_cli_process_exit ->
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

%% RS.1d criterion 5: socket cancellation must expose only soma_service's
%% cleaned terminal projection. The first reply therefore arrives after the
%% CLI worker and its external process are gone; a later connection receives
%% the same projection without appending another durable event.
test_socket_cancel_is_repeatable_after_cli_process_exit(Config) ->
    TmpDir = proplists:get_value(tmp_dir, Config),
    LogPath = proplists:get_value(log_path, Config),
    {Helper, PidFile} = write_cancel_cli_stub(TmpDir),
    ok = soma_tool_registry:register_tool(
           #{name => socket_cancel_cli,
             effect => reader,
             idempotent => true,
             timeout_ms => 60000,
             adapter => cli,
             executable => Helper,
             argv => [PidFile]}),
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        RequestId = <<"socket-service-repeatable-cancel">>,
        Invoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-repeatable-cancel\") "
              "(tool (name socket_cancel_cli) "
              "(args (value \"ignored\"))) "
              "(scope \"socket_cancel_cli\"))">>,

        #{task_id := TaskId, status := accepted} =
            socket_request(Path, Invoke, invoke),
        StorePid = runtime_event_store(),
        WorkerPid = wait_for_task_tool_worker(StorePid, TaskId, 100),
        OsPid = wait_for_cli_os_pid(PidFile, 100),
        try
            ?assert(is_process_alive(WorkerPid)),
            ?assert(cli_os_process_alive(OsPid)),

            Cancel = lifecycle_source(cancel, TaskId),
            ExpectedTerminal =
                #{task_id => TaskId,
                  request_id => RequestId,
                  status => cancelled,
                  summary => #{reason_class => cancelled}},
            InitialResponse = socket_response(Path, Cancel),
            ?assertEqual(
               {service_reply, cancel, ExpectedTerminal},
               InitialResponse),
            ?assertNot(is_process_alive(WorkerPid)),
            ?assertNot(cli_os_process_alive(OsPid)),

            ?assert(filelib:is_regular(LogPath)),
            InitialEventCount =
                length(
                  soma_event_store:by_correlation(StorePid, TaskId)),
            RepeatedResponse = socket_response(Path, Cancel),
            RepeatedEventCount =
                length(
                  soma_event_store:by_correlation(StorePid, TaskId)),
            ?assertEqual(
               {InitialResponse, InitialEventCount},
               {RepeatedResponse, RepeatedEventCount})
        after
            _ = soma_service:cancel(TaskId)
        end
    after
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 6: socket callers must receive bounded public errors rather
%% than internal diagnostics. Version negotiation advertises the exact set
%% owned by soma_service_envelope, while a structurally invalid invoke keeps
%% its distinct operation code. Neither rejected row may start a run.
test_socket_version_and_operation_errors_are_typed(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        Rows =
            [{unsupported_version,
              <<"(invoke "
                "(api-version \"2\") "
                "(request-id \"socket-service-version-2\") "
                "(tool (name echo) (args (value \"ignored\"))))">>,
              {service_error,
               unsupported_api_version,
               [<<"1">>]}},
             {invalid_operation,
              <<"(invoke "
                "(api-version \"1\") "
                "(request-id \"socket-service-no-operation\"))">>,
              {service_error, invalid_operation}}],
        StorePid = runtime_event_store(),
        RunStartsBefore = run_started_count(StorePid),
        Observed =
            [begin
                 Payload = socket_response_payload(Path, Source),
                 {Name,
                  byte_size(Payload),
                  decode_service_response(Payload),
                  run_started_count(StorePid)}
             end
             || {Name, Source, _Expected} <- Rows],

        ?assert(
           lists:all(
             fun({_Name, ReplyBytes, _Reply, _RunStarts}) ->
                     ReplyBytes =< 1048576
             end,
             Observed)),
        ?assertEqual(
           lists:duplicate(length(Rows), RunStartsBefore),
           [RunStarts || {_Name, _Bytes, _Reply, RunStarts} <- Observed]),
        ?assertEqual(
           [{Name, Expected} || {Name, _Source, Expected} <- Rows],
           [{Name, Reply} || {Name, _Bytes, Reply, _RunStarts} <- Observed])
    after
        stop_listener(Listener, Path)
    end.

socket_request(Path, Source, Operation) ->
    {service_reply, Operation, Value} = socket_response(Path, Source),
    Value.

socket_response(Path, Source) ->
    decode_service_response(socket_response_payload(Path, Source)).

socket_response_payload(Path, Source) ->
    {ok, Socket} =
        gen_tcp:connect(
          {local, Path}, 0,
          [binary, {packet, raw}, {active, false}], 5000),
    try
        ok = gen_tcp:send(Socket, frame(Source)),
        recv_frame(Socket)
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
           [code, Code],
           ['supported-api-versions', SupportedApiVersions]]]} ->
            {service_error,
             decode_error_code(Code),
             SupportedApiVersions};
        {ok,
         [[error,
           ['api-version', <<"1">>],
           [code, Code]]]} ->
            {service_error, decode_error_code(Code)}
    end.

decode_error_code('unsupported-api-version') -> unsupported_api_version;
decode_error_code('invalid-operation') -> invalid_operation;
decode_error_code('internal-error') -> internal_error;
decode_error_code(Code) -> Code.

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
decode_key('reason-class') -> reason_class;
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

write_cancel_cli_stub(TmpDir) ->
    Helper = filename:join(TmpDir, "cancel-cli.sh"),
    PidFile = filename:join(TmpDir, "cancel-cli.pid"),
    Script = <<"#!/bin/sh\n"
               "printf '%s\\n' \"$$\" > \"$1\"\n"
               "sleep 30\n">>,
    ok = file:write_file(Helper, Script),
    ok = file:change_mode(Helper, 8#755),
    {Helper, PidFile}.

wait_for_task_tool_worker(_StorePid, _TaskId, 0) ->
    error(service_socket_tool_worker_did_not_start);
wait_for_task_tool_worker(StorePid, TaskId, Attempts) ->
    case [WorkerPid
          || #{event_type := <<"tool.started">>,
               tool_call_pid := WorkerPid} <-
                 soma_event_store:by_correlation(StorePid, TaskId),
             is_pid(WorkerPid)] of
        [WorkerPid | _] ->
            WorkerPid;
        [] ->
            timer:sleep(10),
            wait_for_task_tool_worker(StorePid, TaskId, Attempts - 1)
    end.

wait_for_cli_os_pid(_PidFile, 0) ->
    error(cli_stub_did_not_write_os_pid);
wait_for_cli_os_pid(PidFile, Attempts) ->
    case file:read_file(PidFile) of
        {ok, Bytes} when byte_size(Bytes) > 0 ->
            list_to_integer(string:trim(binary_to_list(Bytes)));
        {ok, _Empty} ->
            timer:sleep(10),
            wait_for_cli_os_pid(PidFile, Attempts - 1);
        {error, enoent} ->
            timer:sleep(10),
            wait_for_cli_os_pid(PidFile, Attempts - 1)
    end.

cli_os_process_alive(OsPid) ->
    Kill = os:find_executable("kill"),
    Port = open_port(
             {spawn_executable, Kill},
             [{args, ["-0", integer_to_list(OsPid)]},
              exit_status, binary, use_stdio, stderr_to_stdout]),
    cli_os_process_probe_result(Port).

cli_os_process_probe_result(Port) ->
    receive
        {Port, {data, _Bytes}} ->
            cli_os_process_probe_result(Port);
        {Port, {exit_status, 0}} ->
            true;
        {Port, {exit_status, _NonZero}} ->
            false
    after 1000 ->
        erlang:port_close(Port),
        error(os_process_probe_timeout)
    end.

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

run_started_count(StorePid) ->
    length(
      [Event
       || Event <- soma_event_store:all(StorePid),
          maps:get(event_type, Event) =:= <<"run.started">>]).

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
