%% @doc AF_UNIX adapter for the public soma_service lifecycle API.
%%
%% Each accepted connection carries one framed Lisp request and one framed Lisp
%% response. The handler only adapts transport data: soma_service remains the
%% task owner and soma_run/soma_tool_call remain the execution path.
-module(soma_service_socket).

-export([start_link/1]).

-define(API_VERSION, <<"1">>).

-spec start_link(#{socket := file:filename_all()}) ->
    {ok, pid()} | {error, term()}.
start_link(#{socket := Path}) ->
    Parent = self(),
    Listener = spawn_link(fun() -> listen(Parent, Path) end),
    receive
        {Listener, listening} ->
            {ok, Listener};
        {Listener, {error, Reason}} ->
            {error, Reason}
    end.

listen(Parent, Path) ->
    case gen_tcp:listen(
           0,
           [{ifaddr, {local, Path}}, binary, {packet, raw},
            {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            Parent ! {self(), listening},
            accept_loop(ListenSocket);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            Handler = spawn(fun() -> wait_then_handle(Socket) end),
            case gen_tcp:controlling_process(Socket, Handler) of
                ok ->
                    Handler ! proceed;
                {error, _Reason} ->
                    exit(Handler, kill),
                    gen_tcp:close(Socket)
            end,
            accept_loop(ListenSocket);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            accept_loop(ListenSocket)
    end.

wait_then_handle(Socket) ->
    receive
        proceed -> handle(Socket)
    end.

handle(Socket) ->
    case soma_socket_frame:recv(Socket, 60000) of
        {ok, Source} ->
            Reply = handle_request(Source),
            _ = soma_socket_frame:send(Socket, Reply);
        {error, frame_too_large} ->
            Reply = soma_lisp:render(service_error(frame_too_large)),
            _ = soma_socket_frame:send(Socket, Reply);
        {error, _Reason} ->
            ok
    end,
    gen_tcp:close(Socket).

handle_request(Source) ->
    Response =
        case soma_lfe:compile(Source, #{}) of
            {ok, Request} ->
                dispatch(Request);
            {error, Diagnostics} ->
                service_diagnostic_error(Diagnostics)
        end,
    soma_lisp:render(Response).

dispatch(#{kind := invoke} = Envelope) ->
    service_reply(invoke, soma_service:invoke(Envelope));
dispatch(#{status := #{task_id := TaskId}}) ->
    service_reply(status, soma_service:status(TaskId));
dispatch(#{result := #{task_id := TaskId}}) ->
    service_reply(result, soma_service:result(TaskId));
dispatch(#{watch := #{task_id := TaskId, limit := Limit} = Watch}) ->
    Cursor = maps:get(cursor, Watch, undefined),
    service_reply(watch, soma_service:watch(TaskId, Cursor, Limit));
dispatch(#{cancel := #{task_id := TaskId}}) ->
    service_reply(cancel, soma_service:cancel(TaskId));
dispatch(_Other) ->
    service_error(internal_error).

service_reply(Operation, {ok, Value}) ->
    #{kind => service_reply,
      api_version => ?API_VERSION,
      operation => Operation,
      value => Value};
service_reply(_Operation, {error, Diagnostics}) when is_list(Diagnostics) ->
    service_diagnostic_error(Diagnostics);
service_reply(_Operation, {error, Reason}) ->
    service_error(public_service_error_code(Reason)).

service_diagnostic_error([#{code := Code} | _]) ->
    service_error(public_diagnostic_code(Code));
service_diagnostic_error([_ReaderDiagnostic | _]) ->
    service_error(malformed_request);
service_diagnostic_error(_Diagnostics) ->
    service_error(internal_error).

public_diagnostic_code(unsupported_api_version) -> unsupported_api_version;
public_diagnostic_code(invalid_operation) -> invalid_operation;
public_diagnostic_code(_Unknown) -> internal_error.

public_service_error_code(not_found) -> not_found;
public_service_error_code(_Unknown) -> internal_error.

service_error(unsupported_api_version) ->
    #{kind => service_error,
      api_version => ?API_VERSION,
      code => unsupported_api_version,
      supported_api_versions =>
          soma_service_envelope:supported_api_versions()};
service_error(Code) ->
    #{kind => service_error,
      api_version => ?API_VERSION,
      code => Code}.
