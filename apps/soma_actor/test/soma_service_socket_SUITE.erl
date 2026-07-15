-module(soma_service_socket_SUITE).

-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_socket_invoke_status_and_result_end_to_end/1,
         test_socket_binary_results_use_lossless_lisp_bytes/1,
         test_socket_disconnect_does_not_cancel_accepted_invocation/1,
         test_socket_duplicate_invoke_reuses_task_once/1,
         test_socket_watch_reconnect_resumes_after_cursor/1,
         test_socket_cancel_is_repeatable_after_cli_process_exit/1,
         test_socket_version_and_operation_errors_are_typed/1,
         test_socket_preserves_published_v1_errors/1,
         test_socket_oversized_response_returns_typed_error/1,
         test_socket_rejects_bad_and_oversized_frames_then_serves/1,
         test_socket_malformed_lifecycle_forms_are_request_errors/1,
         test_socket_unknown_symbols_do_not_grow_atom_table/1,
         test_daemon_service_listener_is_config_opt_in_with_sibling_default/1,
         test_cli_socket_rejects_service_only_forms_and_survives/1,
         test_service_socket_stale_takeover_and_lost_bind_preserve_winner/1,
         test_socket_fresh_symbols_are_deterministic_and_total/1]).

all() ->
    [test_socket_invoke_status_and_result_end_to_end,
     test_socket_binary_results_use_lossless_lisp_bytes,
     test_socket_disconnect_does_not_cancel_accepted_invocation,
     test_socket_duplicate_invoke_reuses_task_once,
     test_socket_watch_reconnect_resumes_after_cursor,
     test_socket_cancel_is_repeatable_after_cli_process_exit,
     test_socket_version_and_operation_errors_are_typed,
     test_socket_preserves_published_v1_errors,
     test_socket_oversized_response_returns_typed_error,
     test_socket_rejects_bad_and_oversized_frames_then_serves,
     test_socket_malformed_lifecycle_forms_are_request_errors,
     test_socket_unknown_symbols_do_not_grow_atom_table,
     test_daemon_service_listener_is_config_opt_in_with_sibling_default,
     test_cli_socket_rejects_service_only_forms_and_survives,
     test_service_socket_stale_takeover_and_lost_bind_preserve_winner,
     test_socket_fresh_symbols_are_deterministic_and_total].

init_per_testcase(
  test_socket_fresh_symbols_are_deterministic_and_total, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [echo]}),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config];
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
init_per_testcase(
  test_daemon_service_listener_is_config_opt_in_with_sibling_default,
  Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [echo]}),
    TmpDir = make_tmp_dir(),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir} | Config];
init_per_testcase(test_socket_preserves_published_v1_errors, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [echo, sleep]}),
    ok = application:set_env(
           soma_actor, service_result_inline_bytes, 1),
    TmpDir = make_tmp_dir(),
    InvalidDataDir = filename:join(TmpDir, "not-a-directory"),
    ok = file:write_file(InvalidDataDir, <<"regular file">>),
    ok = application:set_env(
           soma_actor, service_data_dir, InvalidDataDir),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir} | Config];
init_per_testcase(test_socket_oversized_response_returns_typed_error, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [file_read]}),
    ok = application:set_env(
           soma_actor, service_result_inline_bytes,
           4 * soma_socket_frame:max_bytes()),
    TmpDir = make_tmp_dir(),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir} | Config];
init_per_testcase(test_socket_binary_results_use_lossless_lisp_bytes, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [file_read]}),
    ok = application:set_env(
           soma_actor, service_result_inline_bytes, 64),
    TmpDir = make_tmp_dir(),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir} | Config];
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
    application:unset_env(soma_actor, service_result_inline_bytes),
    application:unset_env(soma_actor, service_data_dir),
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

%% Review regression: service results may contain arbitrary bytes rather than
%% UTF-8 text. Both an inline one-byte file result and an artifact descriptor's
%% external-term prefix must remain valid Lisp on the real socket and decode to
%% the exact public soma_service terms. The v1 byte form is
%% `(bytes (hex "..."))`, using an even-length uppercase hexadecimal payload.
test_socket_binary_results_use_lossless_lisp_bytes(Config) ->
    TmpDir = proplists:get_value(tmp_dir, Config),
    InlineBytes = <<16#ff>>,
    ArtifactBytes = binary:copy(<<16#ff>>, 256),
    InlineFile = "inline-bytes.bin",
    ArtifactFile = "artifact-bytes.bin",
    ok = file:write_file(filename:join(TmpDir, InlineFile), InlineBytes),
    ok = file:write_file(filename:join(TmpDir, ArtifactFile), ArtifactBytes),
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        InlineRequestId = <<"socket-binary-inline">>,
        #{task_id := InlineTaskId} =
            socket_request(
              Path,
              file_read_invoke(InlineRequestId, InlineFile, TmpDir),
              invoke),
        _InlineTerminal =
            wait_for_socket_status(Path, InlineTaskId, succeeded, 100),
        InlinePayload =
            socket_response_payload(
              Path, lifecycle_source(result, InlineTaskId)),

        ArtifactRequestId = <<"socket-binary-artifact">>,
        #{task_id := ArtifactTaskId} =
            socket_request(
              Path,
              file_read_invoke(ArtifactRequestId, ArtifactFile, TmpDir),
              invoke),
        _ArtifactTerminal =
            wait_for_socket_status(Path, ArtifactTaskId, succeeded, 100),
        {ok, ExpectedArtifact} = soma_service:result(ArtifactTaskId),
        ?assertMatch(
           #{truncated_inline := <<131, _/binary>>}, ExpectedArtifact),
        ArtifactPayload =
            socket_response_payload(
              Path, lifecycle_source(result, ArtifactTaskId)),

        Parsed =
            [soma_lfe_reader:read_forms(Payload)
             || Payload <- [InlinePayload, ArtifactPayload]],
        ?assert(
           lists:all(
             fun({ok, [_]}) -> true;
                (_) -> false
             end,
             Parsed)),
        ?assertEqual(
           {service_reply, result,
            #{InlineRequestId => InlineBytes}},
           decode_service_response(InlinePayload)),
        ?assertEqual(
           {service_reply, result, ExpectedArtifact},
           decode_service_response(ArtifactPayload))
    after
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
        InvalidBytesEventId = <<"socket-watch-invalid-bytes">>,
        ok = soma_event_store:append(
               runtime_event_store(),
               #{event_id => InvalidBytesEventId,
                 correlation_id => TaskId,
                 event_type => <<"socket.watch.invalid-bytes">>,
                 payload => #{output => <<16#ff>>,
                              text => <<"base64:/w==">>}}),
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
         #{events := SecondEvents, cursor := SecondCursor}} = SecondResponse,
        SecondIds = [maps:get(event_id, Event)
                     || Event <- SecondEvents],
        ?assertEqual(ExpectedSecondIds, SecondIds),
        ?assertEqual(
           lists:nth(PageLimit + 1, DurableIds), hd(SecondIds)),
        ?assertNotEqual(lists:last(FirstIds), hd(SecondIds)),

        {service_reply, watch, #{events := RemainingEvents}} =
            socket_response(
              Path, watch_source(TaskId, SecondCursor, 100)),
        [InvalidBytesEvent] =
            [Event
             || #{event_id := EventId} = Event <- RemainingEvents,
                EventId =:= InvalidBytesEventId],
        ?assertEqual(
           #{output => <<16#ff>>, text => <<"base64:/w==">>},
           maps:get(payload, InvalidBytesEvent))
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
              <<"(run)">>,
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

%% Review regression: every v1 envelope diagnostic and service lifecycle error
%% must survive the socket adapter's fixed allowlists. The invalid-operation row
%% is a successfully compiled non-service `(run)' shape, while the lifecycle
%% rows are produced by the real supervised service rather than parser failures.
test_socket_preserves_published_v1_errors(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        lists:foreach(
          fun({Source, Expected}) ->
                  ?assertEqual(Expected, socket_response(Path, Source))
          end,
          published_diagnostic_error_rows()),

        FirstInvoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-public-errors\") "
              "(tool (name echo) (args (value \"first\"))))">>,
        #{task_id := FirstTaskId} =
            socket_request(Path, FirstInvoke, invoke),
        ConflictingInvoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-public-errors\") "
              "(tool (name echo) (args (value \"second\"))))">>,
        ?assertEqual(
           {service_error, request_id_conflict},
           socket_response(Path, ConflictingInvoke)),

        _FirstTerminal =
            wait_for_socket_status(Path, FirstTaskId, succeeded, 100),
        ?assertEqual(
           {service_error, invalid_cursor},
           socket_response(
             Path, watch_source(FirstTaskId, <<"not-a-cursor">>, 1))),
        ?assertEqual(
           {service_error, not_running},
           socket_response(
             Path, lifecycle_source(cancel, FirstTaskId))),
        ?assertEqual(
           {service_error, artifact_publish_failed},
           socket_response(
             Path, lifecycle_source(result, FirstTaskId))),

        FailedInvoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-unavailable-result\") "
              "(max-output-bytes 1) "
              "(tool (name echo) (args (value \"too large\"))))">>,
        #{task_id := FailedTaskId} =
            socket_request(Path, FailedInvoke, invoke),
        _FailedTerminal =
            wait_for_socket_status(Path, FailedTaskId, failed, 100),
        ?assertEqual(
           {service_error, result_unavailable},
           socket_response(
             Path, lifecycle_source(result, FailedTaskId))),

        SlowInvoke =
            <<"(invoke "
              "(api-version \"1\") "
              "(request-id \"socket-service-not-ready\") "
              "(tool (name sleep) (args (ms 30000))))">>,
        #{task_id := SlowTaskId} =
            socket_request(Path, SlowInvoke, invoke),
        try
            ?assertEqual(
               {service_error, not_ready},
               socket_response(
                 Path, lifecycle_source(result, SlowTaskId)))
        after
            _ = socket_response(
                  Path, lifecycle_source(cancel, SlowTaskId))
        end
    after
        stop_listener(Listener, Path)
    end.

%% Review regression: a completed service result whose rendered reply exceeds
%% the shared frame cap must receive the small response-too-large error over the
%% same real socket. Closing without a frame would make a retryable presentation
%% outcome indistinguishable from a transport failure.
test_socket_oversized_response_returns_typed_error(Config) ->
    TmpDir = proplists:get_value(tmp_dir, Config),
    LargePath = filename:join(TmpDir, "large-inline-result.bin"),
    LargeBytes =
        binary:copy(<<"x">>, soma_socket_frame:max_bytes() + 65536),
    ok = file:write_file(LargePath, LargeBytes),
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        Invoke =
            iolist_to_binary(
              ["(invoke "
               "(api-version \"1\") "
               "(request-id \"socket-service-large-inline\") "
               "(tool (name file_read) "
               "(args (path \"large-inline-result.bin\") "
               "(root \"", TmpDir, "\"))))"]),
        #{task_id := TaskId} = socket_request(Path, Invoke, invoke),
        Terminal = wait_for_socket_status(Path, TaskId, succeeded, 100),
        #{summary := #{result_bytes := ResultBytes}} = Terminal,
        ?assert(ResultBytes > soma_socket_frame:max_bytes()),

        ?assertEqual(
           {ok, {service_error, response_too_large}},
           socket_response_result(
             Path, lifecycle_source(result, TaskId))),
        ?assert(is_process_alive(Listener)),
        ?assertMatch(
           {service_reply, status, #{status := succeeded}},
           socket_response(
             Path, lifecycle_source(status, TaskId)))
    after
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 7: malformed Lisp and an oversized declared frame are
%% connection-local failures. Each receives its fixed bounded typed error,
%% while the same listener remains alive and serves a valid request on a fresh
%% connection.
test_socket_rejects_bad_and_oversized_frames_then_serves(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        Rows =
            [{zero_length_frame,
              fun() -> <<0:32/unsigned-big-integer>> end,
              malformed_request},
             {malformed_lisp,
              fun() -> frame(<<"(">>) end,
              malformed_request},
             {oversized_frame,
              fun() ->
                      Length = soma_socket_frame:max_bytes() + 1,
                      <<Length:32/unsigned-big-integer>>
              end,
              frame_too_large}],
        lists:foreach(
          fun({Name, WireFrame, ExpectedCode}) ->
                  ErrorPayload =
                      socket_wire_response_payload(Path, WireFrame()),
                  ?assertEqual(
                     {service_error, ExpectedCode},
                     decode_service_response(ErrorPayload)),
                  ?assert(
                     byte_size(ErrorPayload) =<
                         soma_socket_frame:max_bytes()),
                  ?assert(is_process_alive(Listener)),
                  MissingTaskId =
                      iolist_to_binary(
                        ["missing-after-", atom_to_list(Name)]),
                  ?assertEqual(
                     {service_error, not_found},
                     socket_response(
                       Path, lifecycle_source(status, MissingTaskId))),
                  ?assert(is_process_alive(Listener))
          end,
          Rows)
    after
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 7: a syntactically complete lifecycle head with a missing
%% task id is still a malformed client request. It must not be projected as an
%% internal service failure, and each bad connection must leave the listener
%% available for the next request.
test_socket_malformed_lifecycle_forms_are_request_errors(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        lists:foreach(
          fun(Source) ->
                  ?assertEqual(
                     {service_error, malformed_request},
                     socket_response(Path, Source)),
                  ?assert(is_process_alive(Listener))
          end,
          [<<"(status)">>, <<"(result)">>, <<"(cancel)">>]),
        ?assertEqual(
           {service_error, not_found},
           socket_response(
             Path,
             lifecycle_source(
               status, <<"missing-after-malformed-lifecycle">>)))
    after
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 7: the frame cap bounds one request, but only a socket-level
%% atom-count proof catches cumulative interning across many in-cap frames.
%% Warm every exercised path before sampling, then send names that are unique
%% to this test run and prove the listener remains useful without growing the
%% VM atom table.
test_socket_unknown_symbols_do_not_grow_atom_table(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        Seed = integer_to_binary(
                 erlang:unique_integer([positive, monotonic])),
        _WarmUnknown =
            socket_response_payload(
              Path, unknown_operation_source(Seed, 0)),
        ?assertEqual(
           {service_error, not_found},
           socket_response(
             Path, lifecycle_source(status, <<"atom-count-warmup">>))),
        AtomCountBefore = erlang:system_info(atom_count),

        lists:foreach(
          fun(N) ->
                  Payload =
                      socket_response_payload(
                        Path, unknown_operation_source(Seed, N)),
                  ?assert(
                     byte_size(Payload) =<
                         soma_socket_frame:max_bytes())
          end,
          lists:seq(1, 500)),

        ?assert(is_process_alive(Listener)),
        ?assertEqual(
           {service_error, not_found},
           socket_response(
             Path, lifecycle_source(status, <<"atom-count-after">>))),
        ?assertEqual(
           AtomCountBefore,
           erlang:system_info(atom_count))
    after
        stop_listener(Listener, Path)
    end.

%% RS.1d criterion 8: the production nonblocking daemon always starts its CLI
%% socket, but exposes the separate service ingress only when the config file
%% contains a [service] table. An empty table enables the listener and resolves
%% its default beside the configured CLI socket as service.sock.
test_daemon_service_listener_is_config_opt_in_with_sibling_default(Config) ->
    TmpDir = proplists:get_value(tmp_dir, Config),
    CliPath = filename:join(TmpDir, "soma.sock"),
    ServicePath = filename:join(TmpDir, "service.sock"),
    AbsentConfig = filename:join(TmpDir, "service-absent.toml"),
    PresentConfig = filename:join(TmpDir, "service-present.toml"),
    ToolsDir = filename:join(TmpDir, "tools"),
    ok = file:make_dir(ToolsDir),
    ok = file:write_file(AbsentConfig, <<"# service ingress disabled\n">>),
    ok = file:write_file(PresentConfig, <<"[service]\n">>),
    try
        {ok, CliPath} =
            soma_cli:daemon(
              #{socket => CliPath,
                config_path => AbsentConfig,
                tools_dir => ToolsDir}),
        ?assertEqual(0, soma_cli:ping(#{socket => CliPath})),
        ?assertMatch({error, _}, connect_socket(ServicePath)),
        ok = stop_daemon(CliPath),

        {ok, CliPath} =
            soma_cli:daemon(
              #{socket => CliPath,
                config_path => PresentConfig,
                tools_dir => ToolsDir}),
        ?assertEqual(0, soma_cli:ping(#{socket => CliPath})),
        ?assert(service_socket_is_listening(ServicePath)),
        ?assertEqual(
           {service_error, not_found},
           socket_response(
             ServicePath,
             lifecycle_source(status, <<"missing-daemon-service-task">>))),
        ok = stop_daemon(CliPath),

        assert_service_config_rejected(
          ToolsDir,
          <<"[service\n">>,
          {config_error, malformed_table}),
        assert_service_config_rejected(
          ToolsDir,
          <<"[service]\nsocket = 123\n">>,
          {config_error, invalid_service_socket})
    after
        maybe_stop_daemon(CliPath)
    end.

%% Criterion 10 regression proof moved out of the pre-existing CLI wire suite:
%% service-only lifecycle forms must receive a bounded CLI error, and the same
%% CLI listener must remain available for a normal CLI status request.
test_cli_socket_rejects_service_only_forms_and_survives(_Config) ->
    Path = socket_path(),
    {ok, Server} = soma_cli_server:start_link(#{socket => Path}),
    unlink(Server),
    try
        Requests =
            [<<"(result \"not-a-cli-task\")">>,
             <<"(watch \"not-a-cli-task\" (limit 1))">>],
        lists:foreach(
          fun(Request) ->
                  Reply = socket_response_payload(Path, Request),
                  ?assert(byte_size(Reply) =< 1024),
                  ?assertMatch(
                     match,
                     re:run(Reply, "^\\(result ", [{capture, none}])),
                  ?assertMatch(
                     match,
                     re:run(
                       Reply, "\\(status error\\)", [{capture, none}])),
                  ?assertMatch(
                     match,
                     re:run(
                       Reply, "invalid-top-level-form", [{capture, none}])),
                  ?assert(is_process_alive(Server)),
                  Probe =
                      socket_response_payload(
                        Path, <<"(status \"not-a-cli-task\")">>),
                  ?assertMatch(
                     match,
                     re:run(
                       Probe, "\\(state unknown\\)", [{capture, none}]))
          end,
          Requests)
    after
        stop_listener(Server, Path)
    end.

%% RS.1d criterion 9: only a listener that proves a leftover AF_UNIX path is
%% stale may replace it. Once that replacement is live, a later contender must
%% lose without unlinking the winner's path, and the winner must still answer a
%% typed request from a fresh connection after the losing start has returned.
test_service_socket_stale_takeover_and_lost_bind_preserve_winner(_Config) ->
    Path = socket_path(),
    {ok, StaleListener} =
        soma_service_socket:start_link(#{socket => Path}),
    unlink(StaleListener),
    try
        StaleRef = erlang:monitor(process, StaleListener),
        exit(StaleListener, kill),
        receive
            {'DOWN', StaleRef, process, StaleListener, killed} -> ok
        after 5000 ->
            ct:fail(stale_service_listener_did_not_stop)
        end,
        ?assertMatch({ok, #file_info{type = other}},
                     file:read_file_info(Path)),

        ReplacementResult =
            soma_service_socket:start_link(#{socket => Path}),
        ?assertMatch({ok, _}, ReplacementResult),
        {ok, Winner} = ReplacementResult,
        unlink(Winner),
        try
            ?assertEqual(
               {error, address_in_use},
               soma_service_socket:start_link(#{socket => Path})),
            ?assert(is_process_alive(Winner)),
            ?assertEqual(
               {service_error, not_found},
               socket_response(
                 Path,
                 lifecycle_source(
                   status, <<"missing-after-lost-service-bind">>))),
            ?assert(is_process_alive(Winner))
        after
            stop_listener(Winner, Path)
        end
    after
        case is_process_alive(StaleListener) of
            true -> exit(StaleListener, kill);
            false -> ok
        end,
        _ = file:delete(Path)
    end.

published_diagnostic_error_rows() ->
    LargeScopeEntry = binary:copy(<<"s">>, 256),
    [{<<"(invoke "
        "(request-id \"socket-missing-api-version\") "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, missing_api_version}},
     {<<"(invoke "
        "(api-version \"2\") "
        "(request-id \"socket-unsupported-api-version\") "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, unsupported_api_version, [<<"1">>]}},
     {<<"(invoke "
        "(api-version \"1\") "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, missing_request_id}},
     {<<"(invoke "
        "(api-version \"1\") "
        "(request-id invalid) "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, invalid_request_id}},
     {<<"(invoke "
        "(api-version \"1\") "
        "(api-version \"1\") "
        "(request-id \"socket-duplicate-field\") "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, duplicate_field}},
     {<<"(invoke "
        "(api-version \"1\") "
        "(request-id \"socket-unknown-field\") "
        "(credential \"must-not-echo\") "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, unknown_field}},
     {<<"(run)">>,
      {service_error, invalid_operation}},
     {<<"(invoke "
        "(api-version \"1\") "
        "(request-id \"socket-invalid-budget\") "
        "(deadline-ms 0) "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, invalid_budget}},
     {iolist_to_binary(
        ["(invoke "
         "(api-version \"1\") "
         "(request-id \"socket-scope-too-large\") "
         "(scope \"", LargeScopeEntry, "\") "
         "(tool (name echo) (args (value \"ignored\"))))"]),
      {service_error, scope_entry_too_large}},
     {<<"(invoke "
        "(api-version \"1\") "
        "(request-id \"socket-invalid-artifacts\") "
        "(artifacts invalid) "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, invalid_artifacts}},
     {<<"(invoke "
        "(api-version \"1\") "
        "(request-id \"socket-invalid-correlation\") "
        "(correlation-id invalid) "
        "(tool (name echo) (args (value \"ignored\"))))">>,
      {service_error, invalid_correlation_id}},
     {<<"(watch \"socket-invalid-watch\" (limit 0))">>,
      {service_error, invalid_watch}},
     {<<"(status \"socket-missing-task\")">>,
      {service_error, not_found}}].

file_read_invoke(RequestId, FileName, Root) ->
    iolist_to_binary(
      ["(invoke "
       "(api-version \"1\") "
       "(request-id ", soma_lisp:render(RequestId), ") "
       "(tool (name file_read) "
       "(args (path ", soma_lisp:render(list_to_binary(FileName)), ") "
       "(root ", soma_lisp:render(list_to_binary(Root)), "))))"]).

assert_service_config_rejected(ToolsDir, Source, ExpectedReason) ->
    RowDir =
        filename:join(
          "/tmp",
          "soma_sc_" ++ os:getpid() ++ "_" ++
              integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(RowDir),
    CliPath = filename:join(RowDir, "soma.sock"),
    ServicePath = filename:join(RowDir, "service.sock"),
    ConfigPath = filename:join(RowDir, "config.toml"),
    try
        ok = file:write_file(ConfigPath, Source),
        Opts = #{socket => CliPath,
                 config_path => ConfigPath,
                 tools_dir => ToolsDir},
        LoadResult =
            try soma_config:load_service(Opts) of
                ServiceConfig -> {ok, ServiceConfig}
            catch
                error:LoadReason -> {error, LoadReason}
            end,
        DaemonResult = soma_cli:daemon(Opts),
        case DaemonResult of
            {ok, CliPath} -> ok = stop_daemon(CliPath);
            {error, _Reason} -> ok
        end,
        ?assertEqual({error, ExpectedReason}, LoadResult),
        ?assertEqual({error, ExpectedReason}, DaemonResult),
        ?assertMatch({error, _}, connect_socket(CliPath)),
        ?assertMatch({error, _}, connect_socket(ServicePath))
    after
        _ = file:del_dir_r(RowDir)
    end.

%% Review findings (#246): fresh symbols in every accepted invoke position
%% must be total (no reader/parser crash) and deterministic (the same source
%% accepts or rejects identically on a fresh or warm VM — valid v1 semantics
%% never depend on atom-table warm-up). Caller-defined identifiers arrive as
%% binaries; only registered vocabularies (tool names, declared params)
%% resolve against existing atoms.
test_socket_fresh_symbols_are_deterministic_and_total(_Config) ->
    Path = socket_path(),
    {ok, Listener} = soma_service_socket:start_link(#{socket => Path}),
    unlink(Listener),
    try
        Seed = integer_to_binary(
                 erlang:unique_integer([positive, monotonic])),
        %% Warm the shared infrastructure once so the atom-count pin below
        %% measures only the fresh-symbol handling.
        ?assertEqual(
           {service_error, not_found},
           socket_response(
             Path, lifecycle_source(status, <<"fresh-symbol-warmup">>))),
        AtomCountBefore = erlang:system_info(atom_count),

        %% 1) A fresh symbol in a nested arg-value position must not crash
        %% the handler; it arrives at the tool as a binary.
        FreshValue = <<"socket_fresh_value_", Seed/binary>>,
        ValueRequestId = <<"fresh-value-", Seed/binary>>,
        ValueInvoke =
            <<"(invoke (api-version \"1\") "
              "(request-id \"", ValueRequestId/binary, "\") "
              "(tool (name echo) (args (value ",
              FreshValue/binary, "))))">>,
        #{task_id := ValueTaskId, status := accepted} =
            socket_request(Path, ValueInvoke, invoke),
        #{status := succeeded} =
            wait_for_socket_status(Path, ValueTaskId, succeeded, 100),
        ?assertEqual(
           #{ValueRequestId => #{value => FreshValue}},
           socket_request(
             Path, lifecycle_source(result, ValueTaskId), result)),

        %% 2) Fresh step ids and a fresh whole-args from_step reference in a
        %% steps operation are caller correlation data: accepted, executed,
        %% and keyed as binaries in the result.
        StepA = <<"socket_fresh_step_a_", Seed/binary>>,
        StepB = <<"socket_fresh_step_b_", Seed/binary>>,
        StepsRequestId = <<"fresh-steps-", Seed/binary>>,
        StepsInvoke =
            <<"(invoke (api-version \"1\") "
              "(request-id \"", StepsRequestId/binary, "\") "
              "(steps "
              "(step (id ", StepA/binary,
              ") (tool echo) (args (value \"seed\"))) "
              "(step (id ", StepB/binary,
              ") (tool echo) (args (from_step ", StepA/binary, ")))))">>,
        #{task_id := StepsTaskId, status := accepted} =
            socket_request(Path, StepsInvoke, invoke),
        #{status := succeeded} =
            wait_for_socket_status(Path, StepsTaskId, succeeded, 100),
        StepsResult =
            socket_request(
              Path, lifecycle_source(result, StepsTaskId), result),
        ?assertEqual(
           #{value => <<"seed">>}, maps:get(StepA, StepsResult)),
        ?assertEqual(
           #{value => <<"seed">>}, maps:get(StepB, StepsResult)),

        %% 3) The string spelling is the documented equivalent of the same
        %% identifiers: same source shape, same semantics.
        QuotedRequestId = <<"fresh-quoted-", Seed/binary>>,
        QuotedInvoke =
            <<"(invoke (api-version \"1\") "
              "(request-id \"", QuotedRequestId/binary, "\") "
              "(steps "
              "(step (id \"", StepA/binary,
              "\") (tool echo) (args (value \"seed\"))) "
              "(step (id \"", StepB/binary,
              "\") (tool echo) (args (from_step \"", StepA/binary,
              "\")))))">>,
        #{task_id := QuotedTaskId, status := accepted} =
            socket_request(Path, QuotedInvoke, invoke),
        #{status := succeeded} =
            wait_for_socket_status(Path, QuotedTaskId, succeeded, 100),
        ?assertEqual(
           StepsResult,
           socket_request(
             Path, lifecycle_source(result, QuotedTaskId), result)),

        %% 4) A fresh, undeclared arg key is a bounded typed rejection —
        %% echo declares its params, so an unknown name cannot reach it.
        FreshKey = <<"socket_fresh_key_", Seed/binary>>,
        KeyInvoke =
            <<"(invoke (api-version \"1\") "
              "(request-id \"fresh-key-", Seed/binary, "\") "
              "(tool (name echo) (args (", FreshKey/binary,
              " \"v\"))))">>,
        KeyResponse = socket_response(Path, KeyInvoke),
        ?assertMatch({service_error, _}, KeyResponse),

        %% 5) None of the above interned a single new atom, and the
        %% listener still serves.
        ?assert(is_process_alive(Listener)),
        ?assertEqual(
           {service_error, not_found},
           socket_response(
             Path, lifecycle_source(status, <<"fresh-symbol-after">>))),
        ?assertEqual(AtomCountBefore, erlang:system_info(atom_count))
    after
        stop_listener(Listener, Path)
    end.

socket_request(Path, Source, Operation) ->
    {service_reply, Operation, Value} = socket_response(Path, Source),
    Value.

socket_response(Path, Source) ->
    decode_service_response(socket_response_payload(Path, Source)).

socket_response_result(Path, Source) ->
    case socket_response_payload_result(Path, Source) of
        {ok, Payload} ->
            {ok, decode_service_response(Payload)};
        {error, _Reason} = Error ->
            Error
    end.

socket_response_payload(Path, Source) ->
    {ok, Payload} = socket_response_payload_result(Path, Source),
    Payload.

socket_response_payload_result(Path, Source) ->
    socket_wire_response_payload_result(Path, frame(Source)).

socket_wire_response_payload(Path, WireFrame) ->
    {ok, Payload} = socket_wire_response_payload_result(Path, WireFrame),
    Payload.

socket_wire_response_payload_result(Path, WireFrame) ->
    {ok, Socket} =
        gen_tcp:connect(
          {local, Path}, 0,
          [binary, {packet, raw}, {active, false}], 5000),
    try
        ok = gen_tcp:send(Socket, WireFrame),
        recv_frame_result(Socket)
    after
        gen_tcp:close(Socket)
    end.

connect_socket(Path) ->
    gen_tcp:connect(
      {local, Path}, 0,
      [binary, {packet, raw}, {active, false}], 500).

service_socket_is_listening(Path) ->
    case connect_socket(Path) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            true;
        {error, _Reason} ->
            false
    end.

stop_daemon(Path) ->
    0 = soma_cli:stop(#{socket => Path}),
    wait_for_daemon_stop(Path, 100).

maybe_stop_daemon(Path) ->
    case soma_cli:ping(#{socket => Path}) of
        0 -> stop_daemon(Path);
        1 -> ok
    end.

wait_for_daemon_stop(_Path, 0) ->
    error(cli_daemon_did_not_stop);
wait_for_daemon_stop(Path, Attempts) ->
    case soma_cli:ping(#{socket => Path}) of
        1 ->
            ok;
        0 ->
            timer:sleep(10),
            wait_for_daemon_stop(Path, Attempts - 1)
    end.

frame(Payload) ->
    <<(byte_size(Payload)):32/unsigned-big-integer, Payload/binary>>.

recv_frame_result(Socket) ->
    case gen_tcp:recv(Socket, 4, 5000) of
        {ok, <<Length:32/unsigned-big-integer>>} ->
            gen_tcp:recv(Socket, Length, 5000);
        {error, _Reason} = Error ->
            Error
    end.

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
decode_error_code('missing-api-version') -> missing_api_version;
decode_error_code('missing-request-id') -> missing_request_id;
decode_error_code('invalid-request-id') -> invalid_request_id;
decode_error_code('duplicate-field') -> duplicate_field;
decode_error_code('unknown-field') -> unknown_field;
decode_error_code('invalid-operation') -> invalid_operation;
decode_error_code('invalid-budget') -> invalid_budget;
decode_error_code('scope-entry-too-large') -> scope_entry_too_large;
decode_error_code('invalid-artifacts') -> invalid_artifacts;
decode_error_code('invalid-correlation-id') -> invalid_correlation_id;
decode_error_code('malformed-request') -> malformed_request;
decode_error_code('frame-too-large') -> frame_too_large;
decode_error_code('response-too-large') -> response_too_large;
decode_error_code('request-id-conflict') -> request_id_conflict;
decode_error_code('not-found') -> not_found;
decode_error_code('not-ready') -> not_ready;
decode_error_code('result-unavailable') -> result_unavailable;
decode_error_code('invalid-cursor') -> invalid_cursor;
decode_error_code('invalid-watch') -> invalid_watch;
decode_error_code('not-running') -> not_running;
decode_error_code('artifact-publish-failed') -> artifact_publish_failed;
decode_error_code('internal-error') -> internal_error;
decode_error_code(Code) -> Code.

decode_value([event | Pairs]) ->
    maps:from_list(
      [{decode_key(Key), decode_value(Value)}
       || [Key, Value] <- Pairs]);
decode_value([bytes, [hex, Hex]]) when is_binary(Hex) ->
    binary:decode_hex(Hex);
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
decode_key('truncated-inline') -> truncated_inline;
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

unknown_operation_source(Seed, N) ->
    iolist_to_binary(
      ["(socket-unknown-operation-", Seed, "-", integer_to_binary(N), ")"]).

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
