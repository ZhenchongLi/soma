%% @doc CLI.5 command brain. `dispatch/1' takes an argv list, routes the
%% subcommand to the matching `soma_cli:*' thin client, and returns an integer
%% exit code. It parses argv into the same map shape the `soma_cli' functions
%% already take, resolves the socket path, and calls them -- the wire and Lisp
%% rendering stay in `soma_cli'. The `ask' intent is run through
%% `soma_cli_intent:escape/1' so an intent containing `"' or `\\' still emits a
%% valid s-expr the daemon parses, reaching it intact.
-module(soma_cli_main).

-export([dispatch/1, socket/1]).

%% `run File' resolves the socket and drives `soma_cli:run/1', returning its exit
%% code (0 only when the reply carries `(status completed)'). `ask Intent' resolves
%% the socket and drives `soma_cli:ask/1', returning its exit code. `status TaskId'
%% resolves the socket and drives `soma_cli:status/1', returning its exit code (0 on
%% a successful read -- not gated on `(status completed)'). `trace CorrId' resolves
%% the socket and drives `soma_cli:trace/1', returning its exit code (0 on a
%% successful read -- not gated on `(status completed)'). `cancel TaskId' resolves
%% the socket and drives `soma_cli:cancel/1', returning its exit code (0 on a
%% successful cancel). A trailing `--detach' after `run File' or `ask Intent'
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
                 "usage: soma <run|ask|status|trace|cancel> ...\n"),
    2.

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

%% The `detach => true' fragment to merge in when `--detach' was given, else empty.
detach_opt(#{detach := true}) ->
    #{detach => true};
detach_opt(_Opts) ->
    #{}.
