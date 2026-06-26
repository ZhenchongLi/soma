%% @doc CLI daemon socket server. A Unix-domain (`{local, Path}') listener with
%% `{packet, 4}' framing; one handler process per accepted connection. The wire is
%% Lisp s-exprs, and Lisp only: a `(run (step ...) ...)' request is parsed by
%% `soma_lfe:compile/2', run under a `soma_run' the handler owns, and the terminal
%% result is rendered back as a `(result ...)' s-expr by `soma_lisp:render/1'.
-module(soma_cli_server).

-export([start_link/1, frame/1, unframe/1]).

%% Start the listener. `start_link(#{socket => Path})' opens an AF_UNIX
%% (`{local, Path}') listening socket with `{packet, 4}' framing and runs an
%% accept loop in a linked process, spawning one handler per accepted connection.
-spec start_link(#{socket := file:filename_all()}) ->
    {ok, pid()} | {error, term()}.
start_link(#{socket := Path}) ->
    Parent = self(),
    Pid = spawn_link(fun() -> listen(Parent, Path) end),
    receive
        {Pid, listening} -> {ok, Pid};
        {Pid, {error, Reason}} -> {error, Reason}
    end.

listen(Parent, Path) ->
    _ = unlink_stale(Path),
    case gen_tcp:listen(0, [{ifaddr, {local, Path}},
                            {packet, 4}, binary,
                            {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            Parent ! {self(), listening},
            accept_loop(ListenSocket);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

%% Unlink only a *stale* leftover at Path -- a file no live server answers --
%% so a restart after a crash that left a socket file still binds, while a live
%% server's path is left alone (a second start_link then fails the bind rather
%% than stealing the path). Probe by connecting: if a server answers, the path
%% is live and untouched; if no file is there, or nothing answers, clear it.
unlink_stale(Path) ->
    case file:read_file_info(Path) of
        {ok, _} ->
            case gen_tcp:connect({local, Path}, 0,
                                 [binary, {active, false}], 200) of
                {ok, Probe} ->
                    gen_tcp:close(Probe);
                {error, _} ->
                    file:delete(Path)
            end;
        {error, _} ->
            ok
    end.

accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            spawn(fun() -> handle(Socket) end),
            accept_loop(ListenSocket);
        {error, closed} ->
            ok
    end.

%% Per-connection handler, one process per accepted connection. It reads one
%% framed `(run ...)' request, drives a supervised run it owns directly, frames
%% the terminal `(result ...)' s-expr back, then closes. The socket is
%% `{packet, 4}', so the driver strips the length prefix on recv and prepends it
%% on send -- the payload here is the bare s-expr.
handle(Socket) ->
    case gen_tcp:recv(Socket, 0, 60000) of
        {ok, Bytes} ->
            Reply = handle_lisp_request(Bytes),
            _ = gen_tcp:send(Socket, iolist_to_binary(Reply)),
            gen_tcp:close(Socket);
        {error, _} ->
            ok
    end.

%% Parse the Lisp `(run ...)' request with `soma_lfe', run it, and render the
%% terminal result map as a `(result ...)' s-expr. A malformed request --
%% `soma_lfe:compile/2' returning `{error, Diagnostics}', or the reader crashing
%% on garbage bytes -- is not a handler crash: it renders a `(result ...)' with
%% `status => error' and an `error' sub-form carrying the diagnostics.
handle_lisp_request(Bytes) ->
    Compiled = try soma_lfe:compile(Bytes, #{})
               catch
                   Class:Reason ->
                       {error, [#{code => malformed_request,
                                  message => iolist_to_binary(
                                               io_lib:format("~p:~p",
                                                             [Class, Reason]))}]}
               end,
    case Compiled of
        {ok, #{run := #{steps := Steps}}} ->
            run_steps(Steps);
        {error, Diagnostics} ->
            soma_lisp:render(#{status => error, error => Diagnostics})
    end.

run_steps(Steps) ->
    TaskId = mint_id("task"),
    CorrId = mint_id("corr"),
    RunId = mint_id("run"),
    {ok, _RunPid} = soma_run_sup:start_run(
        #{run_id => RunId,
          session_id => TaskId,
          session_pid => self(),
          steps => Steps,
          correlation_id => CorrId}),
    Result = await_run(RunId, TaskId, CorrId),
    soma_lisp:render(Result).

%% Wait for the owned run's terminal message and shape the result map. On
%% `run_completed' the recorded step outputs become the `outputs' sub-form; on a
%% failure the status is non-`completed' and the reason travels in `error'.
await_run(RunId, TaskId, CorrId) ->
    receive
        {run_completed, RunId, Outputs} ->
            #{status => completed,
              task_id => TaskId,
              correlation_id => CorrId,
              outputs => Outputs};
        {run_failed, RunId, Reason} ->
            #{status => failed,
              task_id => TaskId,
              correlation_id => CorrId,
              error => Reason};
        {run_timeout, RunId} ->
            #{status => timeout, task_id => TaskId, correlation_id => CorrId};
        {run_cancelled, RunId} ->
            #{status => cancelled, task_id => TaskId, correlation_id => CorrId}
    end.

mint_id(Prefix) ->
    list_to_binary(
      Prefix ++ "-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

%% Prepend a 4-byte big-endian length prefix to an s-expr payload, the wire frame
%% a client reads. `{packet, 4}' produces the same shape in the driver; this is
%% the pure, documented contract a non-Erlang client reproduces.
-spec frame(iodata()) -> iolist().
frame(Payload) ->
    Bin = iolist_to_binary(Payload),
    [<<(byte_size(Bin)):32/big>>, Bin].

%% Split the 4-byte big-endian length prefix off a frame, returning the payload.
-spec unframe(binary()) -> binary().
unframe(<<Len:32/big, Payload:Len/binary>>) ->
    Payload.
