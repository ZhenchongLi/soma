%% @doc Four-byte unsigned big-endian framing for local Soma sockets.
-module(soma_socket_frame).

-export([max_bytes/0, recv/2, send/2, frame/1, unframe/1]).

-define(MAX_BYTES, 1048576).

-spec max_bytes() -> pos_integer().
max_bytes() ->
    ?MAX_BYTES.

-spec recv(gen_tcp:socket(), timeout()) ->
    {ok, binary()} | {error, term()}.
recv(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 4, Timeout) of
        {ok, <<0:32/unsigned-big-integer>>} ->
            {ok, <<>>};
        {ok, <<Length:32/unsigned-big-integer>>}
          when Length =< ?MAX_BYTES ->
            gen_tcp:recv(Socket, Length, Timeout);
        {ok, <<_Length:32/unsigned-big-integer>>} ->
            {error, frame_too_large};
        {error, _Reason} = Error ->
            Error
    end.

-spec send(gen_tcp:socket(), iodata()) -> ok | {error, term()}.
send(Socket, Payload0) ->
    Payload = iolist_to_binary(Payload0),
    case byte_size(Payload) =< ?MAX_BYTES of
        true ->
            gen_tcp:send(Socket, frame(Payload));
        false ->
            {error, frame_too_large}
    end.

%% @doc Build the compatibility frame exposed by soma_cli_server:frame/1.
-spec frame(iodata()) -> iolist().
frame(Payload0) ->
    Payload = iolist_to_binary(Payload0),
    [<<(byte_size(Payload)):32/unsigned-big-integer>>, Payload].

%% @doc Decode one already-buffered compatibility frame.
-spec unframe(binary()) -> binary().
unframe(<<Length:32/unsigned-big-integer,
          Payload:Length/binary>>) ->
    Payload.
