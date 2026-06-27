%% @doc One-shot local socket capture used by soma_cli_SUITE client tests.
-module(soma_cli_request_capture).

-export([start/2, request/1]).

start(Path, Reply) ->
    Parent = self(),
    Pid = spawn_link(fun() -> listen(Parent, Path, Reply) end),
    receive
        {Pid, listening} ->
            Pid;
        {Pid, {error, Reason}} ->
            exit({request_capture_listen_failed, Reason})
    after 5000 ->
            exit(request_capture_listen_timeout)
    end.

request(Pid) ->
    receive
        {Pid, request, Request} ->
            Request;
        {Pid, {error, Reason}} ->
            exit({request_capture_failed, Reason})
    after 5000 ->
            exit(request_capture_timeout)
    end.

listen(Parent, Path, Reply) ->
    _ = file:delete(Path),
    case gen_tcp:listen(0, [{ifaddr, {local, Path}},
                            {packet, 4}, binary,
                            {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            Parent ! {self(), listening},
            accept_one(Parent, ListenSocket, Reply);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

accept_one(Parent, ListenSocket, Reply) ->
    case gen_tcp:accept(ListenSocket, 10000) of
        {ok, Socket} ->
            capture_request(Parent, ListenSocket, Socket, Reply);
        {error, Reason} ->
            ok = gen_tcp:close(ListenSocket),
            Parent ! {self(), {error, Reason}}
    end.

capture_request(Parent, ListenSocket, Socket, Reply) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Request} ->
            ok = gen_tcp:send(Socket, Reply),
            ok = gen_tcp:close(Socket),
            ok = gen_tcp:close(ListenSocket),
            Parent ! {self(), request, Request};
        {error, Reason} ->
            ok = gen_tcp:close(Socket),
            ok = gen_tcp:close(ListenSocket),
            Parent ! {self(), {error, Reason}}
    end.
