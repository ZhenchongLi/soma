%% @doc CLI.1b thin client. `run/1' resolves a task source, sends it to a
%% `soma_cli_server' over a local Unix socket, prints the `(result ...)' reply,
%% and returns an exit code. The client does not parse Lisp; only the CLI.4
%% detach flag mutates the request text to carry a `(detach)' marker.
-module(soma_cli).

-export([run/1, ask/1, trace/1, status/1, cancel/1, stop/1, ping/1, daemon/1,
         daemon_foreground/1, ensure_daemon/2, resolve_socket/1,
         tool_register/1, tool_list/1, tool_remove/1]).

%% Resolve the task source (a file path, or stdin when the path arg is `-'),
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
    io:format("~ts~n", [Reply]),
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
    io:format("~ts~n", [Reply]),
    exit_code(Reply).

%% Wrap the intent string in an `(ask (intent "..."))' s-expr, rendered through
%% `soma_lisp:render/1' so it is escaped and quoted like any other Lisp string.
%% The escript passes argv as a list of Unicode codepoints (not raw bytes), so
%% a non-ASCII intent (e.g. Chinese) must go through `unicode:characters_to_binary/1'
%% first -- splicing the codepoint list directly into an iolist crashes
%% `iolist_to_binary/1' on any codepoint above 255.
ask_source(Intent) ->
    iolist_to_binary(["(ask (intent ",
                      soma_lisp:render(unicode:characters_to_binary(Intent)),
                      "))"]).

ask_source(Intent, #{detach := true}) ->
    iolist_to_binary(["(ask (intent ",
                      soma_lisp:render(unicode:characters_to_binary(Intent)),
                      ") (detach))"]);
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
    io:format("~ts~n", [Reply]),
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
    io:format("~ts~n", [Reply]),
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
    io:format("~ts~n", [Reply]),
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
    io:format("~ts~n", [Reply]),
    stop_exit_code(Reply).

%% Exit 0 when the rendered reply carries `(status stopped)', non-zero otherwise.
stop_exit_code(Reply) ->
    case re:run(Reply, "\\(status stopped\\)", [{capture, none}]) of
        match -> 0;
        nomatch -> 1
    end.

%% Read the `(tool ...)' manifest file, wrap its bytes as a
%% `(tool-register (tool ...))' frame, and drive the same connect / frame+send /
%% read / print path as the other client commands. The client does not parse the
%% manifest -- the daemon is the only parser; the client only reads the file and
%% wraps it. A successful daemon reply returns exit 0.
-spec tool_register(map()) -> non_neg_integer().
tool_register(#{file := File, socket := Path}) ->
    Source = tool_register_source(read_source(File)),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~ts~n", [Reply]),
    0.

%% Wrap the manifest file's `(tool ...)' bytes in a `(tool-register ...)' s-expr.
tool_register_source(Manifest) ->
    iolist_to_binary(["(tool-register ", Manifest, ")"]).

%% Send `(tool-list)' and print the daemon's `(tool-list ...)' reply -- the
%% live registry's catalog projection. Same connect / frame+send / read /
%% print shape as `tool_register/1'.
-spec tool_list(map()) -> non_neg_integer().
tool_list(#{socket := Path}) ->
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(tool-list)">>),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~ts~n", [Reply]),
    0.

%% Send `(tool-remove "<name>")' for a config-registered tool and print the
%% daemon's reply. The name travels as a Lisp string; the daemon is the only
%% parser and never mints an atom from it.
-spec tool_remove(map()) -> non_neg_integer().
tool_remove(#{name := Name, socket := Path}) ->
    Source = iolist_to_binary(["(tool-remove ", soma_lisp:render(
                                                    unicode:characters_to_binary(Name)),
                               ")"]),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~ts~n", [Reply]),
    0.

%% Liveness probe. Resolve the socket the same way the other client funcs do,
%% then attempt a `{local, Path}' connect that sends no request and closes
%% immediately. Exit 0 when a `soma_cli_server' is listening (the connect
%% succeeds); a connect failure (no listener) falls through to exit 1.
-spec ping(map()) -> non_neg_integer().
ping(Args) ->
    Path = resolve_socket(Args),
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {packet, 4}, {active, false}]) of
        {ok, Sock} ->
            ok = gen_tcp:close(Sock),
            0;
        {error, _} ->
            1
    end.

%% Decide-and-wait auto-start. Probe once with `ping/1': when a `soma_cli_server'
%% is already listening on the resolved socket the probe returns `0', so the
%% daemon is up -- return `ok' and never touch `LaunchFun'. When the probe returns
%% `1' nothing is listening, so call `LaunchFun' exactly once (the seam a test
%% mocks and production fills with the real detached spawn) and then poll `ping/1'
%% on a bound -- the same ~80-attempt / 25ms range the ping tests poll with --
%% returning `ok' the moment a probe returns `0'. (The bounded-error path when the
%% launch never brings a listener up is added in a later cycle.)
-spec ensure_daemon(map(), fun(() -> term())) -> ok | {error, term()}.
ensure_daemon(Args, LaunchFun) when is_function(LaunchFun, 0) ->
    case ping(Args) of
        0 ->
            ok;
        1 ->
            _ = LaunchFun(),
            poll_until_listening(Args, 80)
    end.

%% Poll `ping/1' on a bound, sleeping 25ms between attempts, and return `ok' the
%% moment a probe returns `0' (a listener is up). The bound caps the wait so a
%% launch that never binds cannot loop forever.
poll_until_listening(_Args, 0) ->
    {error, daemon_not_listening};
poll_until_listening(Args, N) ->
    case ping(Args) of
        0 ->
            ok;
        1 ->
            timer:sleep(25),
            poll_until_listening(Args, N - 1)
    end.

%% Boot the daemon: start the runtime, then a `soma_cli_server' listener on a
%% resolved socket path. A test-supplied `socket' override points both ends at a
%% temp path; absent it, resolve `$XDG_RUNTIME_DIR/soma.sock', else
%% `/tmp/soma-$UID.sock'. Returns `{ok, Path}' -- the listener runs in its own
%% linked process, so the daemon stays up without blocking the caller.
-spec daemon(map()) -> {ok, file:filename_all()} | {error, term()}.
daemon(Args) ->
    case load_model_config(Args) of
        {ok, ModelConfig} -> daemon_with_model_config(Args, ModelConfig);
        {error, Reason} -> {error, Reason}
    end.

daemon_with_model_config(Args, ModelConfig) ->
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    %% Config-registered cli tools load after the runtime (the registry must
    %% be up) and before the listener starts. The result is log lines + data;
    %% a broken tool file never stops boot.
    ToolsDir = resolve_tools_dir(Args),
    _ = soma_tool_config:load_dir(ToolsDir),
    Path = resolve_socket(Args),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig,
                                                 tools_dir => ToolsDir}),
    {ok, Path}.

%% Boot the daemon and block until the listener exits -- the blocking sibling of
%% `daemon/1' for a standalone daemon BEAM. It does what `daemon/1' does (start
%% the runtime, start `soma_actor_sup' so the `ask' path's `start_actor/1' has a
%% live supervisor, resolve the socket, load the model config, start the linked
%% listener), then monitors the listener pid and waits for its `DOWN'. When a
%% `(stop)' closes the listen socket the listener ends its accept loop and exits,
%% the monitor fires, and this call returns -- so the BEAM the wrapper launched
%% reaches the end of its work and halts. The `start_link' link stays: a listener
%% crash propagates over it and takes the daemon process down rather than being
%% turned into a clean return. The monitor is the additional handle for the
%% normal-stop case. Config is loaded before the listener is started: a provider
%% config that cannot read `SOMA_LLM_API_KEY' returns `{error, Reason}' to the CLI
%% entry point, so `soma daemon' can exit non-zero with a diagnostic instead of
%% crashing. `soma_actor_sup' is a named singleton, so a second
%% `start_link' returns `{error, {already_started, Pid}}', which we tolerate.
%% When the listener `start_link/1' returns `{error, _}' -- the path is already
%% bound by a live winner of an auto-start race -- this redundant daemon returns
%% `ok' and exits cleanly rather than crashing on the lost bind.
-spec daemon_foreground(map()) -> ok | {error, term()}.
daemon_foreground(Args) ->
    case load_model_config(Args) of
        {ok, ModelConfig} -> daemon_foreground_with_model_config(Args, ModelConfig);
        {error, Reason} -> {error, Reason}
    end.

daemon_foreground_with_model_config(Args, ModelConfig) ->
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    %% Same boot step as `daemon/1': config tools load after the runtime and
    %% before the listener starts.
    ToolsDir = resolve_tools_dir(Args),
    _ = soma_tool_config:load_dir(ToolsDir),
    case soma_actor_sup:start_link() of
        {ok, _Sup} -> ok;
        {error, {already_started, _Sup}} -> ok
    end,
    Path = resolve_socket(Args),
    case soma_cli_server:start_link(#{socket => Path,
                                      model_config => ModelConfig,
                                      tools_dir => ToolsDir}) of
        {ok, Server} ->
            Ref = monitor(process, Server),
            receive
                {'DOWN', Ref, process, Server, _Reason} ->
                    ok
            end;
        {error, _Reason} ->
            %% Lost the bind: the path is already served by a live listener
            %% (the winner of an auto-start race), so this redundant daemon has
            %% nothing to do -- return cleanly and let the process exit instead
            %% of crashing on the failed bind.
            ok
    end.

%% The tools-dir resolver, mirroring `soma_config''s path seam: a `tools_dir'
%% key in `Args' wins (the hermetic-test seam), else `$HOME/.soma/tools'.
resolve_tools_dir(#{tools_dir := Dir}) ->
    Dir;
resolve_tools_dir(_Args) ->
    case os:getenv("HOME") of
        false -> "/.soma/tools";
        Home -> filename:join([Home, ".soma", "tools"])
    end.

load_model_config(Args) ->
    try soma_config:load(Args) of
        ModelConfig -> {ok, ModelConfig}
    catch
        error:Reason -> {error, Reason}
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

%% Resolve the task source bytes from the path arg: `-' reads stdin (the process
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
    case re:run(Source, "^(\\s*\\((?:run|task))(\\s|\\))", [{capture, [1], index}]) of
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
