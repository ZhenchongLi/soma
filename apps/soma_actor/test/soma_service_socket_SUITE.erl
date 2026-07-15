-module(soma_service_socket_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_socket_invoke_status_and_result_end_to_end/1,
         test_socket_disconnect_does_not_cancel_accepted_invocation/1]).

all() ->
    [test_socket_invoke_status_and_result_end_to_end,
     test_socket_disconnect_does_not_cancel_accepted_invocation].

init_per_testcase(_TestCase, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy, #{allowed_tools => [echo]}),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(_TestCase, _Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    application:unset_env(soma_actor, service_policy),
    application:unload(soma_actor),
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

socket_request(Path, Source, Operation) ->
    {ok, Socket} =
        gen_tcp:connect(
          {local, Path}, 0,
          [binary, {packet, raw}, {active, false}], 5000),
    try
        ok = gen_tcp:send(Socket, frame(Source)),
        Reply = recv_frame(Socket),
        decode_service_reply(Reply, Operation)
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

decode_service_reply(Payload, Operation) ->
    {ok,
     [[reply,
       ['api-version', <<"1">>],
       [operation, Operation],
       [value, EncodedValue]]]} = soma_lfe_reader:read_forms(Payload),
    decode_value(EncodedValue).

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
