%% @doc CLI.1 daemon socket server. This slice adds the pure term->JSON shaping
%% layer; the Unix listener, framing, and run handler arrive in later cycles.
%%
%% `encode_response/1' turns a Soma result term into the JSON bytes a client
%% reads. OTP 29's `json:encode/1' already maps atoms and binaries to strings,
%% leaves numbers as numbers, renders lists as arrays, and maps as objects with
%% stringified keys -- exactly the shape this surface needs for plain terms.
-module(soma_cli_server).

-export([start_link/1, encode_response/1, frame/1, unframe/1]).

%% Start the listener. `start_link(#{socket => Path})' opens an AF_UNIX
%% (`{local, Path}') listening socket with `{packet, 4}' framing and runs an
%% accept loop in a linked process, spawning one handler per accepted
%% connection. This cycle only needs the listener to exist and accept a
%% connect; the handler currently just holds the connection -- decoding and
%% running a request arrive in later cycles.
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
%% framed `run' request, drives a supervised run it owns directly, frames the
%% terminal result back, then closes. The socket is `{packet, 4}', so the driver
%% strips the length prefix on recv and prepends it on send -- the payload here is
%% the bare JSON.
handle(Socket) ->
    case gen_tcp:recv(Socket, 0, 60000) of
        {ok, Bytes} ->
            Reply = dispatch_request(Bytes),
            _ = gen_tcp:send(Socket, iolist_to_binary(Reply)),
            gen_tcp:close(Socket);
        {error, _} ->
            ok
    end.

%% The wire is Lisp s-exprs: a `(run (step ...) ...)' request is parsed by
%% `soma_lfe:compile/2' into the atom-keyed step maps `soma_run' accepts, run
%% under a `soma_run' the handler owns, and the terminal result is rendered back
%% as a `(result ...)' s-expr by `soma_lisp:render/1'. The legacy JSON `{...}'
%% request shape is still served for the pre-CLI.1b cases -- dispatch on the
%% first non-whitespace byte: `(' is Lisp, anything else is JSON.
dispatch_request(Bytes) ->
    case first_byte(Bytes) of
        $( ->
            handle_lisp_request(Bytes);
        _ ->
            encode_response(handle_request(json:decode(Bytes)))
    end.

first_byte(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    first_byte(Rest);
first_byte(<<C, _/binary>>) ->
    C;
first_byte(<<>>) ->
    0.

%% Parse the Lisp `(run ...)' request with `soma_lfe', run it, and render the
%% terminal result map as a `(result ...)' s-expr. Criterion 1 needs only the
%% completed echo path: compile -> run -> render of the completed result map.
handle_lisp_request(Bytes) ->
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Bytes, #{}),
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

%% Decode a `run' request, start a `soma_run' the handler owns (session_pid =>
%% self(), a minted correlation_id), wait for its terminal message, and shape the
%% result into the response map. The JSON step list is converted into the
%% atom-keyed step maps `soma_run' accepts (the tool name becomes an atom so the
%% registry can resolve it).
handle_request(#{<<"cmd">> := <<"run">>, <<"workflow">> := Workflow}) ->
    TaskId = mint_id("task"),
    CorrId = mint_id("corr"),
    RunId = mint_id("run"),
    Steps = [shape_step(Step) || Step <- Workflow],
    {ok, _RunPid} = soma_run_sup:start_run(
        #{run_id => RunId,
          session_id => TaskId,
          session_pid => self(),
          steps => Steps,
          correlation_id => CorrId}),
    await_run(RunId, TaskId, CorrId).

%% Wait for the owned run's terminal message and shape the response. On
%% `run_completed' the recorded step outputs become the `outputs' object; on a
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

%% Shape one JSON step object (binary keys) into the step map `soma_run' accepts.
%% `tool' must be an atom for the registry to resolve it; `id' and `args' carry
%% through as the decoded request terms.
shape_step(Step) ->
    #{id => maps:get(<<"id">>, Step),
      tool => binary_to_existing_atom(maps:get(<<"tool">>, Step), utf8),
      args => maps:get(<<"args">>, Step, #{})}.

mint_id(Prefix) ->
    list_to_binary(
      Prefix ++ "-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

%% Encode a Soma result term to JSON bytes. Returns an iolist (the `json'
%% encoder's native output); callers that need a binary wrap with
%% `iolist_to_binary/1'.
%%
%% A reason tuple `{Tag, Detail...}' is shaped to
%% `{"tag":"<Tag>","detail":[<Detail...>]}' so a caller can switch on `tag'
%% without parsing a string; `json:encode/1' has no tuple encoding of its own.
-spec encode_response(term()) -> iolist().
encode_response(Term) ->
    json:encode(jsonable(Term)).

%% Recursively make a term JSON-encodable. `json:encode/1' has no tuple clause, so
%% any tuple -- a reason like `{unregistered_tool, T}' / `{budget_exceeded, _}'
%% nested under `error', or a tuple inside a step's `outputs' -- would crash the
%% encoder. Map every tuple to `{"tag": First, "detail": [Rest...]}' (so a caller
%% switches on `tag' without parsing a string), recursing through maps and lists.
jsonable(T) when is_map(T) ->
    maps:map(fun(_K, V) -> jsonable(V) end, T);
jsonable(T) when is_list(T) ->
    [jsonable(E) || E <- T];
jsonable(T) when is_tuple(T) ->
    [Tag | Detail] = tuple_to_list(T),
    #{tag => Tag, detail => [jsonable(E) || E <- Detail]};
jsonable(T) when is_atom(T); is_binary(T); is_number(T) ->
    T;
jsonable(T) ->
    %% pids, refs, funs, ports -- not JSON-encodable; render for the audit trail
    %% rather than crash the encoder on a failure reason that carries one.
    iolist_to_binary(io_lib:format("~p", [T])).

%% Prepend a 4-byte big-endian length prefix to a JSON payload, the wire frame
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
