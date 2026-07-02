%% @doc CT proofs for the socket tool-management verbs (#220): `soma tool
%% register|list|remove'. The client-side wire cases (a verb renders and sends
%% the right s-expr over the socket) use `soma_cli_request_capture' standing in
%% for the daemon so the test reads the exact bytes sent. The server-side cases
%% boot a real daemon over a temp socket + tools dir.
-module(soma_tool_management_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_register_sends_manifest_over_socket/1,
         test_register_tool_resolves_before_restart/1,
         test_register_writes_normalized_manifest_file/1,
         test_restart_after_register_resolves_from_file/1,
         test_register_invalid_manifest_returns_normalize_error/1]).

all() ->
    [test_register_sends_manifest_over_socket,
     test_register_tool_resolves_before_restart,
     test_register_writes_normalized_manifest_file,
     test_restart_after_register_resolves_from_file,
     test_register_invalid_manifest_returns_normalize_error].

init_per_testcase(_Case, Config) ->
    %% A unique per-run socket path in a temp dir the client verb and the
    %% capture both use, so the client's connect lands on the capture's listener.
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Base = filename:join(Tmp,
                         "soma_tool_mgmt_" ++ os:getpid() ++ "_"
                         ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Base, "x")),
    SocketPath = filename:join(Base, "soma.sock"),
    _ = file:delete(SocketPath),
    [{base_dir, Base}, {socket_path, SocketPath} | Config].

end_per_testcase(_Case, Config) ->
    _ = application:stop(soma_runtime),
    _ = file:delete(?config(socket_path, Config)),
    ok.

%% Criterion 1 (#220): `soma_cli_main:dispatch(["tool", "register", File])' reads
%% the `(tool ...)' manifest file and sends it over the local socket wrapped as a
%% `(tool-register (tool ...))' frame -- the client renders the request, the
%% daemon is the only parser. A `soma_cli_request_capture' stands in for the
%% daemon on the resolved socket so the test reads the exact wire bytes the
%% client sent; the `--socket' override points the client at the capture's path.
test_register_sends_manifest_over_socket(Config) ->
    Path = ?config(socket_path, Config),
    Manifest = <<"(tool\n"
                 "  (name \"cfg_upper\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\" \"world\"))\n">>,
    File = filename:join(?config(base_dir, Config), "cfg_upper.lisp"),
    ok = file:write_file(File, Manifest),
    Capture = soma_cli_request_capture:start(
                Path, <<"(tool-registered (name \"cfg_upper\"))">>),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["tool", "register", File, "--socket", Path]),
    ct:capture_stop(),
    _ = ct:capture_get(),
    Request = soma_cli_request_capture:request(Capture),

    %% The emitted request is a `(tool-register (tool ...))' frame carrying the
    %% manifest's declared name, proving the client read the file and wrapped it.
    match = re:run(Request, "^\\(tool-register ", [{capture, none}]),
    match = re:run(Request, "\\(tool", [{capture, none}]),
    match = re:run(Request, "\\(name \"cfg_upper\"\\)", [{capture, none}]),
    0 = Exit.

%% Criterion 2 (#220): a valid register request makes the named cli tool
%% resolve in the running daemon before any restart. The daemon boots with an
%% empty tools dir, so the declared name does not resolve yet; the test sends a
%% real `(tool-register (tool ...))' frame over the socket, and afterwards
%% `soma_tool_registry:resolve_descriptor/1' returns the registered `cli'
%% descriptor -- proving the server register handler compiled, normalized, and
%% registered the tool in the live registry.
test_register_tool_resolves_before_restart(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% Nothing named `mgmt_upper' is registered at boot (empty tools dir).
    {error, not_found} = soma_tool_registry:resolve_descriptor(mgmt_upper),
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_upper\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    _Reply = register_over_socket(SocketPath, Manifest),
    %% After the register the name resolves live in the running registry to a
    %% `cli' descriptor carrying the declared executable.
    {ok, Descriptor} = soma_tool_registry:resolve_descriptor(mgmt_upper),
    #{adapter := cli, executable := Executable} = Descriptor,
    <<"/bin/echo">> = unicode:characters_to_binary(Executable),
    ok.

%% Criterion 3 (#220): a successful register writes exactly one normalized
%% `(tool ...)' file to the configured tools directory as `<name>.lisp'. The
%% daemon boots with an empty tools dir; after a valid register the tools dir
%% holds one file `mgmt_writer.lisp' whose contents parse as a single
%% `(tool ...)' form that compiles back to a manifest for the declared name --
%% proving the handler rendered and persisted a normalized manifest file.
test_register_writes_normalized_manifest_file(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% The tools dir is empty at boot -- no `.lisp' files yet.
    [] = lists:sort(filelib:wildcard(filename:join(ToolsDir, "*.lisp"))),
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_writer\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    _Reply = register_over_socket(SocketPath, Manifest),

    %% Exactly one `.lisp' file was written, and it is `<name>.lisp'.
    ExpectedFile = filename:join(ToolsDir, "mgmt_writer.lisp"),
    [ExpectedFile] = lists:sort(filelib:wildcard(filename:join(ToolsDir, "*.lisp"))),

    %% The file contents parse as a single normalized `(tool ...)' form that
    %% compiles back to a manifest for the declared name.
    {ok, Written} = file:read_file(ExpectedFile),
    {ok, [ToolForm]} = soma_lfe_reader:read_forms(Written),
    {ok, #{name := mgmt_writer, adapter := cli}} =
        soma_tool_config:compile_form(ToolForm),
    ok.

%% Criterion 4 (#220): a restart after register resolves the tool from the
%% persisted file -- the round-trip the register write and the boot loader share.
%% The daemon boots with an empty tools dir; a valid register writes
%% `mgmt_reboot.lisp' and registers the tool live. The daemon is then stopped and
%% the runtime reset -- the live registration is gone, only the file on disk
%% remains -- and a fresh `soma_cli:daemon/1' boots against the same tools dir.
%% After the reboot the name resolves again, proving the boot-time
%% `soma_tool_config:load_dir/1' re-read and re-registered the persisted manifest
%% (not a lingering live registration).
test_restart_after_register_resolves_from_file(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    %% First boot: empty tools dir, so the name does not resolve yet.
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    {error, not_found} = soma_tool_registry:resolve_descriptor(mgmt_reboot),
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_reboot\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    _Reply = register_over_socket(SocketPath, Manifest),
    %% The register took live before any restart.
    {ok, _Live} = soma_tool_registry:resolve_descriptor(mgmt_reboot),

    %% Stop the daemon (tear the listener down and wait for the socket to go)
    %% and reset the runtime so the live registration is gone -- only the
    %% persisted file remains as the hand-off.
    _ = stop_over_socket(SocketPath),
    ok = wait_socket_gone(SocketPath, 50),
    _ = application:stop(soma_runtime),

    %% Reboot against the same tools dir: `load_dir/1' re-registers from the file.
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    {ok, Descriptor} = soma_tool_registry:resolve_descriptor(mgmt_reboot),
    #{adapter := cli, executable := Executable} = Descriptor,
    <<"/bin/echo">> = unicode:characters_to_binary(Executable),
    ok.

%% Criterion 5 (#220): a register request carrying an invalid manifest returns
%% the same named `{error, Reason}' that `soma_tool_manifest:normalize/1' itself
%% produces -- the server must surface normalize's reason verbatim, never rename
%% it. The daemon boots with an empty tools dir; the test sends a
%% `(tool-register (tool ...))' frame whose body carries a bad `effect' value
%% (`effect banana'), and asserts the wire reply is a failed result whose reason
%% is the exact rendering of normalize's own `{invalid_effect, banana}'.
test_register_invalid_manifest_returns_normalize_error(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_bad\")\n"
                 "  (effect banana) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,

    %% The reason `normalize/1' itself produces for this exact manifest, taken
    %% through the same compile path the server uses.
    {ok, [ToolForm]} = soma_lfe_reader:read_forms(Manifest),
    {ok, BadManifest} = soma_tool_config:compile_form(ToolForm),
    {error, {invalid_effect, banana}} =
        soma_tool_manifest:normalize(BadManifest),
    Expected = iolist_to_binary(soma_lisp:render({invalid_effect, banana})),

    %% The daemon rejects the register and carries that reason verbatim on the
    %% wire -- a failed result whose `error' sub-form is normalize's own reason.
    Reply = register_over_socket(SocketPath, Manifest),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),
    {_, _} = binary:match(Reply, Expected),
    ok.

%% Send a framed `(stop)' over the daemon's socket to tear the listener down,
%% the way the `soma stop' client does, and return the reply bytes.
stop_over_socket(SocketPath) ->
    {ok, Sock} = gen_tcp:connect({local, SocketPath}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    Reply.

%% Poll until the daemon's listen socket at Path stops answering, so a reboot
%% binds a fresh listener instead of racing the old one still closing.
wait_socket_gone(_Path, 0) ->
    {error, still_listening};
wait_socket_gone(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {active, false}], 200) of
        {ok, Probe} ->
            gen_tcp:close(Probe),
            timer:sleep(50),
            wait_socket_gone(Path, N - 1);
        {error, _} ->
            ok
    end.

%% Wrap the manifest bytes as a `(tool-register (tool ...))' frame, send it over
%% the daemon's socket the way the real `soma_cli:tool_register/1' client does,
%% and return the daemon's reply bytes.
register_over_socket(SocketPath, Manifest) ->
    Source = iolist_to_binary(["(tool-register ", Manifest, ")"]),
    {ok, Sock} = gen_tcp:connect({local, SocketPath}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    Reply.
