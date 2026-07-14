%% @doc CLI.5 command brain. `dispatch/1' takes an argv list, routes the
%% subcommand to the matching `soma_cli:*' thin client, and returns an integer
%% exit code. It parses argv into the same map shape the `soma_cli' functions
%% already take, resolves the socket path, and calls them -- the wire and Lisp
%% rendering stay in `soma_cli'. The `ask' intent is run through
%% `soma_cli_intent:escape/1' so an intent containing `"' or `\\' still emits a
%% valid s-expr the daemon parses, reaching it intact.
-module(soma_cli_main).

-export([main/1, main_argv/0, dispatch/1, socket/1]).

%% Process entry point. Dispatch the argv to its subcommand and halt the OS
%% process with the resulting integer exit code, so the shell sees the right
%% status. `dispatch/1' already routes every diagnostic (the usage message) to
%% `standard_error', leaving stdout for a subcommand's reply -- `main/1' adds no
%% output of its own.
-spec main([string()]) -> no_return().
main(Argv) ->
    %% `standard_io' defaults to `latin1' encoding for an escript. Every
    %% `soma_cli' reply is a UTF-8 binary (Lisp strings round-trip non-ASCII
    %% content, e.g. a Chinese `ask' intent/reply); printing it through a
    %% `latin1' device double-encodes each byte as its own codepoint. Set the
    %% device to `unicode' before any subcommand prints, so `~ts' output is
    %% the exact original bytes.
    ok = io:setopts(standard_io, [{encoding, unicode}]),
    halt(dispatch(Argv)).

%% Entry point for the packaged `soma' wrapper. The wrapper passes the user's
%% argv after `-extra' (so flag-shaped tokens like `--detach' reach the program
%% instead of being parsed as `erl' flags), and this reads them back through
%% `init:get_plain_arguments/0' before dispatching. Equivalent to `main/1' on
%% that argv.
-spec main_argv() -> no_return().
main_argv() ->
    Argv = init:get_plain_arguments(),
    %% Auto-start a daemon for a client verb if none is up. This lives in the real
    %% CLI entry (`main_argv/0'), not in `dispatch/1', so the unit tests that call
    %% `dispatch/1' directly are never perturbed by an extra probe connection.
    _ = ensure_daemon_for(Argv),
    main(Argv).

%% `run File' resolves the socket and drives `soma_cli:run/1', returning its exit
%% code (0 only when the reply carries `(status completed)'). `ask Intent' resolves
%% the socket and drives `soma_cli:ask/1', returning its exit code. `status TaskId'
%% resolves the socket and drives `soma_cli:status/1', returning its exit code (0 on
%% a successful read -- not gated on `(status completed)'). `trace CorrId' resolves
%% the socket and drives `soma_cli:trace/1', returning its exit code (0 on a
%% successful read -- not gated on `(status completed)'). `cancel TaskId' resolves
%% the socket and drives `soma_cli:cancel/1', returning its exit code (0 on a
%% successful cancel). `stop' resolves the socket and drives `soma_cli:stop/1',
%% returning its exit code (0 on a successful stop). A trailing `--detach' after
%% `run File' or `ask Intent'
%% sets `detach => true' in the dispatched args, so the emitted request carries the
%% `(detach)' marker.
-spec dispatch([string()]) -> integer().
dispatch(["run", File | Flags]) ->
    with_flags(Flags, fun(Opts) ->
        soma_cli:run(maps:merge(#{file => File, socket => socket(Opts)},
                                detach_opt(Opts)))
    end);
dispatch(["ask", Intent | Flags]) ->
    %% Escape `"' / `\\' in the user intent so the `(ask (intent "..."))' request
    %% `soma_cli:ask/1' renders is a valid s-expr the daemon parses, and the
    %% original string reaches the daemon intact.
    with_flags(Flags, fun(Opts) ->
        soma_cli:ask(maps:merge(#{intent => soma_cli_intent:escape(Intent),
                                  socket => socket(Opts)},
                                detach_opt(Opts)))
    end);
dispatch(["status", TaskId | Flags]) ->
    with_flags(Flags, fun(Opts) ->
        soma_cli:status(#{task_id => TaskId, socket => socket(Opts)})
    end);
dispatch(["trace", CorrId | Flags]) ->
    with_flags(Flags, fun(Opts) ->
        soma_cli:trace(#{correlation_id => CorrId, socket => socket(Opts)})
    end);
dispatch(["cancel", TaskId | Flags]) ->
    with_flags(Flags, fun(Opts) ->
        soma_cli:cancel(#{task_id => TaskId, socket => socket(Opts)})
    end);
dispatch(["tool", "register", File | Flags]) ->
    %% Resolve the socket and drive `soma_cli:tool_register/1', which reads the
    %% `(tool ...)' manifest file and sends it wrapped as a `(tool-register ...)'
    %% frame over the socket. Returns its exit code.
    with_flags(Flags, fun(Opts) ->
        soma_cli:tool_register(#{file => File, socket => socket(Opts)})
    end);
dispatch(["tool", "list" | Flags]) ->
    %% Resolve the socket and drive `soma_cli:tool_list/1', which sends the
    %% `(tool-list)' frame and prints the catalog projection reply.
    with_flags(Flags, fun(Opts) ->
        soma_cli:tool_list(#{socket => socket(Opts)})
    end);
dispatch(["tool", "remove", Name | Flags]) ->
    %% Resolve the socket and drive `soma_cli:tool_remove/1', which sends the
    %% `(tool-remove "<name>")' frame for a config-registered tool.
    with_flags(Flags, fun(Opts) ->
        soma_cli:tool_remove(#{name => Name, socket => socket(Opts)})
    end);
dispatch(["stop" | Flags]) ->
    with_flags(Flags, fun(Opts) ->
        soma_cli:stop(#{socket => socket(Opts)})
    end);
dispatch(["daemon" | Flags]) ->
    %% Boot the daemon in the foreground and block while it serves. Unlike the
    %% other verbs this one does not return until a `(stop)' tears the listener
    %% down; `daemon_foreground/1' returns `ok' on that clean stop, which maps to
    %% exit code 0. Startup config failures return `{error, _}' and are reported
    %% to stderr with a non-zero exit code, before any listener is started.
    with_flags(Flags, fun(Opts) ->
        case soma_cli:daemon_foreground(#{socket => socket(Opts)}) of
            ok -> 0;
            {error, Reason} -> daemon_error(Reason)
        end
    end);
dispatch(["__ping" | Flags]) ->
    %% Wrapper-internal liveness probe -- not a user-facing verb, so it stays out
    %% of `usage/0'. Resolve the socket and drive `soma_cli:ping/1', returning its
    %% exit code (0 when a listener answers, 1 when none does). The wrapper uses
    %% this to decide whether a daemon is already up before auto-starting one.
    with_flags(Flags, fun(Opts) ->
        soma_cli:ping(#{socket => socket(Opts)})
    end);
%% Malformed argv -- no subcommand at all, an unknown subcommand, or a known
%% subcommand missing its required positional -- has no matching clause above.
%% Print a usage message to stderr (stdout stays clean for the well-formed
%% reply paths), and return a non-zero exit code.
dispatch(_Argv) ->
    usage().

%% Write the usage message to standard_error and return the non-zero exit code
%% for malformed invocation. stdout is left untouched so diagnostics never mix
%% with a subcommand's reply.
usage() ->
    io:put_chars(standard_error,
                 "usage: soma <run|ask|status|trace|cancel|tool|stop|daemon> ...\n"
                 "       soma tool <register <file>|list|remove <name>>\n"),
    2.

daemon_error({missing_env, "SOMA_LLM_API_KEY"}) ->
    io:put_chars(standard_error,
                 "soma daemon: missing SOMA_LLM_API_KEY for configured LLM\n"),
    1;
daemon_error({config_error, Name}) ->
    io:format(standard_error, "soma daemon: config error: ~p~n", [Name]),
    1;
daemon_error(Reason) ->
    io:format(standard_error, "soma daemon: startup failed: ~p~n", [Reason]),
    1.

%% Parse the trailing flags, then run `Run(Opts)' for a well-formed flag list.
%% A malformed flag list -- an unknown flag, or `--socket' with no following
%% value -- has no valid parse, so it routes to the usage path instead of letting
%% `parse_flags/1' raise a `function_clause' (which would make `dispatch/1' crash
%% rather than return an integer). Returns whatever `Run/1' or `usage/0' returns.
with_flags(Flags, Run) ->
    case parse_flags(Flags) of
        {ok, Opts} -> Run(Opts);
        error -> usage()
    end.

%% Parse the trailing flags after a subcommand's positional: `--detach' (a marker)
%% and `--socket <path>' (the resolver override). Returns `{ok, OptsMap}' for a
%% well-formed flag list, or `error' for an unknown flag or a `--socket' with no
%% following value.
parse_flags([]) ->
    {ok, #{}};
parse_flags(["--detach" | Rest]) ->
    add_flag(parse_flags(Rest), detach, true);
parse_flags(["--socket", Path | Rest]) ->
    add_flag(parse_flags(Rest), socket, Path);
parse_flags(_Other) ->
    error.

%% Fold a key/value into a `{ok, Map}' parse result, propagating an earlier
%% `error' unchanged.
add_flag({ok, Opts}, Key, Value) ->
    {ok, Opts#{Key => Value}};
add_flag(error, _Key, _Value) ->
    error.

%% The socket the subcommand connects to. Both override and fallback go through
%% the shared `soma_cli:resolve_socket/1' so a separately-launched client lands
%% on the exact path `soma_cli:daemon/1' resolves for the same user: a `--socket'
%% override wins, else `$XDG_RUNTIME_DIR/soma.sock', else a per-user
%% `/tmp/soma-<user>.sock'.
socket(Opts) ->
    soma_cli:resolve_socket(Opts).

%% Before a client verb runs, make sure a daemon is up -- auto-start one if none
%% is, best-effort (if it never comes up the command runs anyway and fails with
%% its own clear connection error). Only the client verbs auto-start, including
%% the three `tool' management verbs; `daemon' / `stop' / `__ping' and malformed
%% argv do not.
ensure_daemon_for([Verb | Rest])
  when Verb =:= "run"; Verb =:= "ask"; Verb =:= "status";
       Verb =:= "cancel"; Verb =:= "trace" ->
    ensure_daemon_for_client(Rest);
ensure_daemon_for(["tool", "register", _File | Rest]) ->
    ensure_daemon_for_client(Rest);
ensure_daemon_for(["tool", "list" | Rest]) ->
    ensure_daemon_for_client(Rest);
ensure_daemon_for(["tool", "remove", _Name | Rest]) ->
    ensure_daemon_for_client(Rest);
ensure_daemon_for(_Argv) ->
    ok.

ensure_daemon_for_client(Rest) ->
    Sock = socket(socket_opts(Rest)),
    soma_cli:ensure_daemon(#{socket => Sock}, fun() -> launch_daemon(Sock) end).

%% Pull just the `--socket <path>' override out of a verb's trailing args so the
%% auto-start resolves the exact socket the command will use; other tokens are
%% ignored here (the command's own flag parsing handles them).
socket_opts(["--socket", Path | _]) ->
    #{socket => Path};
socket_opts([_ | Rest]) ->
    socket_opts(Rest);
socket_opts([]) ->
    #{}.

%% The production launch seam for auto-start: spawn a `soma daemon' process so it
%% outlives this short-lived client process. `SOMA_SELF' is the `soma' wrapper's
%% own path, published by the wrapper; the executable and socket path are passed
%% as argv, never interpolated through a shell.
launch_daemon(Sock) ->
    case os:getenv("SOMA_SELF") of
        false ->
            %% Not invoked through the `soma' wrapper (e.g. a direct dispatch in a
            %% test) -- there is no known binary to launch, so do nothing.
            ok;
        "" ->
            ok;
        Self ->
            try
                _Port = open_port({spawn_executable, Self},
                                  [nouse_stdio, exit_status,
                                   {args, ["daemon", "--socket", Sock]}]),
                ok
            catch
                error:badarg ->
                    ok
            end,
            ok
    end.

%% The `detach => true' fragment to merge in when `--detach' was given, else empty.
detach_opt(#{detach := true}) ->
    #{detach => true};
detach_opt(_Opts) ->
    #{}.
