%% @doc CLI.1b thin client. `run/1' resolves a workflow source, sends it to a
%% `soma_cli_server' over a local Unix socket, prints the `(result ...)' reply,
%% and returns an exit code. The client does not parse Lisp; only the CLI.4
%% detach flag mutates the request text to carry a `(detach)' marker.
-module(soma_cli).

-export([run/1, ask/1, trace/1, status/1, cancel/1, stop/1, daemon/1,
         daemon_foreground/1, resolve_socket/1]).

%% Resolve the workflow source (a file path, or stdin when the path arg is `-'),
%% connect to the resolved socket path with `{packet, 4}', frame + send the source
%% bytes, read the framed `(result ...)' reply, print it to stdout, and return an
%% exit code: 0 when the reply's status sub-form is `completed', non-zero otherwise.
-spec run(map()) -> non_neg_integer().
run(#{file := File, socket := Path} = Args) ->
    Source = run_source(read_source(File), Args),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    exit_code(Reply).

%% Build the `(ask (intent "..."))' source from the intent string client-side --
%% the daemon is the only parser -- then drive the same connect / frame+send /
%% read / print / exit-code path as `run/1'. The reply is the framed
%% `(result ...)' s-expr; exit 0 when its status sub-form is `completed'. The mock
%% (or a real provider) lives at the daemon's `model_config'; the client never
%% sends a model.
-spec ask(map()) -> non_neg_integer().
ask(#{intent := Intent, socket := Path} = Args) ->
    Source = ask_source(Intent, Args),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    exit_code(Reply).

%% Wrap the intent string in an `(ask (intent "..."))' s-expr. The intent is a
%% quoted Lisp string, so it is the literal bytes between the quotes.
ask_source(Intent) ->
    iolist_to_binary(["(ask (intent \"", Intent, "\"))"]).

ask_source(Intent, #{detach := true}) ->
    iolist_to_binary(["(ask (intent \"", Intent, "\") (detach))"]);
ask_source(Intent, _Args) ->
    ask_source(Intent).

%% Build the `(trace "<corr>")' read request client-side -- the daemon is the only
%% parser -- then drive the same connect / frame+send / read / print path as
%% `run/1' and `ask/1'. The reply is the framed `(trace ...)' s-expr carrying the
%% correlation chain's events. A read command always returns exit 0: a successful
%% read is not gated on `(status completed)'.
-spec trace(map()) -> non_neg_integer().
trace(#{correlation_id := CorrId, socket := Path}) ->
    Source = trace_source(CorrId),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    0.

%% Wrap the correlation id in a `(trace "...")' s-expr -- the literal bytes between
%% the quotes.
trace_source(CorrId) ->
    iolist_to_binary(["(trace \"", CorrId, "\")"]).

%% Build the `(status "<task>")' read request client-side -- the daemon is the only
%% parser -- then drive the same connect / frame+send / read / print path as
%% `run/1', `ask/1', and `trace/1'. The reply is the framed `(status ...)' s-expr
%% carrying the task's `(state ...)'. A read command always returns exit 0: a
%% successful read is not gated on `(status completed)'.
-spec status(map()) -> non_neg_integer().
status(#{task_id := TaskId, socket := Path}) ->
    Source = status_source(TaskId),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    0.

%% Wrap the task id in a `(status "...")' s-expr -- the literal bytes between the
%% quotes.
status_source(TaskId) ->
    iolist_to_binary(["(status \"", TaskId, "\")"]).

%% Build the `(cancel "<task>")' request client-side -- the daemon is the only
%% parser -- then drive the same connect / frame+send / read / print path as the
%% other CLI commands. A successful daemon reply returns exit 0.
-spec cancel(map()) -> non_neg_integer().
cancel(#{task_id := TaskId, socket := Path}) ->
    Source = cancel_source(TaskId),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    0.

%% Wrap the task id in a `(cancel "...")' s-expr -- the literal bytes between the
%% quotes.
cancel_source(TaskId) ->
    iolist_to_binary(["(cancel \"", TaskId, "\")"]).

%% Build the bare `(stop)' request client-side -- the daemon is the only parser --
%% then drive the same connect / frame+send / read / print path as the other CLI
%% commands. The reply is the terminal `(result (status stopped))' s-expr; exit 0
%% when its status sub-form is `stopped', non-zero otherwise.
-spec stop(map()) -> non_neg_integer().
stop(#{socket := Path}) ->
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    stop_exit_code(Reply).

%% Exit 0 when the rendered reply carries `(status stopped)', non-zero otherwise.
stop_exit_code(Reply) ->
    case re:run(Reply, "\\(status stopped\\)", [{capture, none}]) of
        match -> 0;
        nomatch -> 1
    end.

%% Boot the daemon: start the runtime, then a `soma_cli_server' listener on a
%% resolved socket path. A test-supplied `socket' override points both ends at a
%% temp path; absent it, resolve `$XDG_RUNTIME_DIR/soma.sock', else
%% `/tmp/soma-$UID.sock'. Returns `{ok, Path}' -- the listener runs in its own
%% linked process, so the daemon stays up without blocking the caller.
-spec daemon(map()) -> {ok, file:filename_all()}.
daemon(Args) ->
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    Path = resolve_socket(Args),
    ModelConfig = soma_config:load(Args),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    {ok, Path}.

%% Boot the daemon and block until its listener terminates, then return `ok'.
%% The packaged `soma daemon' command runs this so the BEAM stays alive while the
%% daemon serves, and exits cleanly once `soma stop' tears the listener down: the
%% `(stop)' teardown ends the listener's accept loop (a normal process exit),
%% which this monitor observes as a `DOWN'. A listener crash arrives over the
%% `start_link' link and takes this process -- and the BEAM -- down with it.
%% Unlike `daemon/1', this also starts `soma_actor', so the `ask' decision path
%% is live in a standalone daemon (not only when a test pre-starts the actor sup).
-spec daemon_foreground(map()) -> ok.
daemon_foreground(Args) ->
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    %% The `ask' path needs `soma_actor_sup' registered. Start the actor app only
    %% if nothing has started its supervisor already, so this is correct both in a
    %% bare-`erl' daemon (nothing pre-started -> start the app) and under a test or
    %% release that already brought the actor supervisor up.
    _ = case whereis(soma_actor_sup) of
            undefined ->
                {ok, _} = application:ensure_all_started(soma_actor);
            _Pid ->
                ok
        end,
    Path = resolve_socket(Args),
    ModelConfig = soma_config:load(Args),
    {ok, ServerPid} = soma_cli_server:start_link(#{socket => Path,
                                                   model_config => ModelConfig}),
    Ref = erlang:monitor(process, ServerPid),
    receive
        {'DOWN', Ref, process, ServerPid, _Reason} ->
            ok
    end.

%% Shared socket-path resolver. Both `daemon/1' and `soma_cli_main' call this so
%% the daemon and a separately-launched client land on the same path. A `socket'
%% override (a temp path a test points both ends at) wins; otherwise
%% `$XDG_RUNTIME_DIR/soma.sock' when set, else a per-user `/tmp/soma-$UID.sock'.
-spec resolve_socket(map()) -> file:filename_all().
resolve_socket(#{socket := Path}) ->
    Path;
resolve_socket(_Args) ->
    case os:getenv("XDG_RUNTIME_DIR") of
        false ->
            "/tmp/soma-" ++ per_user_id() ++ ".sock";
        Dir ->
            filename:join(Dir, "soma.sock")
    end.

%% The per-user segment of the fallback socket path. It must be reproducible
%% from the real user identity so a separately-launched daemon and client land
%% on the same path -- never from `os:getpid()', which differs per OS process.
%% Prefer `$USER'/`$LOGNAME'; fall back to the numeric uid from a shell-free
%% `id -u'.
per_user_id() ->
    case os:getenv("USER") of
        [_ | _] = User ->
            User;
        _ ->
            case os:getenv("LOGNAME") of
                [_ | _] = Logname ->
                    Logname;
                _ ->
                    string:trim(os:cmd("id -u"))
            end
    end.

%% Resolve the workflow bytes from the path arg: `-' reads stdin (the process
%% group leader) to EOF, any other value reads that file. Detach handling is the
%% only client-side source rewrite; parsing and validation remain in the daemon.
read_source("-") ->
    read_stdin([]);
read_source(File) ->
    {ok, Source} = file:read_file(File),
    Source.

run_source(Source, #{detach := true}) ->
    add_run_detach(Source);
run_source(Source, _Args) ->
    Source.

add_run_detach(Source) ->
    case re:run(Source, "^(\\s*\\(run)(\\s|\\))", [{capture, [1], index}]) of
        {match, [{Start, Len}]} ->
            Split = Start + Len,
            <<Prefix:Split/binary, Rest/binary>> = Source,
            <<Prefix/binary, " (detach)", Rest/binary>>;
        nomatch ->
            Source
    end.

%% Read stdin to EOF via the IO protocol on the group leader, accumulating each
%% chunk; return the concatenated bytes as a binary.
read_stdin(Acc) ->
    case io:get_chars(standard_io, "", 65536) of
        eof ->
            iolist_to_binary(lists:reverse(Acc));
        {error, _} = Err ->
            error(Err);
        Data ->
            read_stdin([Data | Acc])
    end.

%% Exit 0 when the rendered reply carries `(status completed)', non-zero
%% otherwise -- the same substring check the CT cases use to read the status.
exit_code(Reply) ->
    case re:run(Reply, "\\(status completed\\)", [{capture, none}]) of
        match -> 0;
        nomatch -> 1
    end.
