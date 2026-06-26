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
    unlink_stale(Path),
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

%% Per-connection handler. For this cycle it simply holds the connection open
%% until the client disconnects; the run handler is a later cycle.
handle(Socket) ->
    receive
        {tcp_closed, Socket} -> ok;
        {tcp_error, Socket, _} -> ok
    after 60000 ->
        gen_tcp:close(Socket)
    end.

%% Encode a Soma result term to JSON bytes. Returns an iolist (the `json'
%% encoder's native output); callers that need a binary wrap with
%% `iolist_to_binary/1'.
%%
%% A reason tuple `{Tag, Detail...}' is shaped to
%% `{"tag":"<Tag>","detail":[<Detail...>]}' so a caller can switch on `tag'
%% without parsing a string; `json:encode/1' has no tuple encoding of its own.
-spec encode_response(term()) -> iolist().
encode_response(Term) when is_tuple(Term), tuple_size(Term) >= 1 ->
    [Tag | Detail] = tuple_to_list(Term),
    json:encode(#{tag => Tag, detail => Detail});
encode_response(Term) ->
    json:encode(Term).

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
