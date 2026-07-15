-module(soma_service_socket_boundary_tests).

-include_lib("eunit/include/eunit.hrl").

%% RS.1d criterion 10: both socket adapters delegate their framing and path
%% ownership to the two shared production helpers. The service adapter remains
%% an edge-only Lisp compiler/service/Lisp renderer and cannot execute runtime
%% work directly. The mature CLI disconnect cancellation proof stays in its
%% unchanged wire suite while the transport beneath it is shared.
test_socket_adapters_share_transport_and_service_keeps_runtime_boundary() ->
    CliImports = imports(soma_cli_server),
    ServiceImports = imports(soma_service_socket),

    assert_imports(
      soma_cli_server,
      CliImports,
      [{soma_socket_frame, recv, 2},
       {soma_socket_frame, send, 2},
       {soma_socket_frame, frame, 1},
       {soma_socket_frame, unframe, 1},
       {soma_socket_path, listen, 1},
       {soma_socket_path, close, 2}]),
    assert_imports(
      soma_service_socket,
      ServiceImports,
      [{soma_socket_frame, recv, 2},
       {soma_socket_frame, send, 2},
       {soma_socket_path, listen, 1},
       {soma_socket_path, close, 2}]),

    assert_imports(
      soma_service_socket,
      ServiceImports,
      [{soma_lfe, compile, 2},
       {soma_service, invoke, 1},
       {soma_service, status, 1},
       {soma_service, result, 1},
       {soma_service, watch, 3},
       {soma_service, cancel, 1},
       {soma_lisp, render, 1}]),
    ForbiddenRuntimeModules =
        [soma_run, soma_run_sup, soma_tool_call, soma_llm_call],
    ?assertEqual(
       [],
       [{Module, Function, Arity}
        || {Module, Function, Arity} <- ServiceImports,
           lists:member(Module, ForbiddenRuntimeModules)]),

    CodecSource = source(soma_socket_frame),
    PathSource = source(soma_socket_path),
    CliSource = source(soma_cli_server),
    ServiceSource = source(soma_service_socket),
    ?assertEqual(1048576, soma_socket_frame:max_bytes()),
    assert_contains(soma_socket_frame, CodecSource, <<"gen_tcp:recv(">>),
    assert_contains(soma_socket_frame, CodecSource, <<"gen_tcp:send(">>),
    assert_contains(soma_socket_path, PathSource, <<"gen_tcp:listen(">>),
    assert_contains(soma_socket_path, PathSource, <<"file:delete(Path)">>),
    lists:foreach(
      fun({Module, ListenerSource}) ->
          assert_absent(Module, ListenerSource,
                        [<<"gen_tcp:listen(">>,
                         <<"gen_tcp:recv(">>,
                         <<"gen_tcp:send(">>,
                         <<"file:delete(Path)">>,
                         <<"unlink_stale">>,
                         <<"{packet, 4}">>,
                         <<":32/big">>,
                         <<":32/unsigned-big-integer">>])
      end,
      [{soma_cli_server, CliSource},
       {soma_service_socket, ServiceSource}]),

    assert_contains(soma_cli_server, CliSource,
                    <<"{tcp_closed, Socket}">>),
    assert_contains(soma_cli_server, CliSource, <<"RunPid ! cancel">>),
    CliSuiteSource = test_source(<<"soma_cli_server_SUITE.erl">>),
    assert_contains(soma_cli_server_SUITE, CliSuiteSource,
                    <<"test_run_cancelled_on_client_disconnect">>).

socket_adapters_share_transport_and_service_keeps_runtime_boundary_test() ->
    test_socket_adapters_share_transport_and_service_keeps_runtime_boundary().

imports(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    {ok, {Module, [{imports, Imports}]}} =
        beam_lib:chunks(code:which(Module), [imports]),
    Imports.

source(Module) ->
    Path = filename:join(
             [code:lib_dir(soma_actor), "src", atom_to_list(Module) ++ ".erl"]),
    {ok, Source} = file:read_file(Path),
    Source.

test_source(File) ->
    Path = filename:join(
             [code:lib_dir(soma_actor), "test", binary_to_list(File)]),
    {ok, Source} = file:read_file(Path),
    Source.

assert_imports(Owner, Imports, ExpectedImports) ->
    lists:foreach(
      fun(Expected) ->
          ?assertEqual({Owner, Expected, true},
                       {Owner, Expected, lists:member(Expected, Imports)})
      end,
      ExpectedImports).

assert_contains(Owner, Source, Marker) ->
    ?assertEqual({Owner, Marker, present},
                 {Owner, Marker, marker_state(Source, Marker)}).

assert_absent(Owner, Source, Markers) ->
    lists:foreach(
      fun(Marker) ->
          ?assertEqual({Owner, Marker, absent},
                       {Owner, Marker, marker_state(Source, Marker)})
      end,
      Markers).

marker_state(Source, Marker) ->
    case binary:match(Source, Marker) of
        nomatch -> absent;
        {_Offset, _Length} -> present
    end.
