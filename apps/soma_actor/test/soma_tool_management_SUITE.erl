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
         test_register_invalid_manifest_returns_normalize_error/1,
         test_failed_register_leaves_tools_dir_unchanged/1,
         test_failed_register_leaves_registry_clean/1,
         test_register_builtin_name_reserved/1,
         test_register_existing_config_tool_already_registered/1,
         test_list_returns_summary_fields/1,
         test_list_omits_internal_fields/1,
         test_remove_config_tool_unresolved/1]).

all() ->
    [test_register_sends_manifest_over_socket,
     test_register_tool_resolves_before_restart,
     test_register_writes_normalized_manifest_file,
     test_restart_after_register_resolves_from_file,
     test_register_invalid_manifest_returns_normalize_error,
     test_failed_register_leaves_tools_dir_unchanged,
     test_failed_register_leaves_registry_clean,
     test_register_builtin_name_reserved,
     test_register_existing_config_tool_already_registered,
     test_list_returns_summary_fields,
     test_list_omits_internal_fields,
     test_remove_config_tool_unresolved].

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

%% Criterion 6 (#220): a failed register leaves the configured tools directory
%% unchanged. Validation (compile + normalize + admission) runs before any disk
%% write, so a rejected request never writes a `<name>.lisp' file. The daemon
%% boots with an empty tools dir; the test snapshots the directory, sends a
%% register whose manifest is rejected by `normalize/1' (`effect banana'), and
%% asserts the directory listing is byte-for-byte identical afterwards -- no
%% `mgmt_nowrite.lisp' appeared.
test_failed_register_leaves_tools_dir_unchanged(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% Snapshot the tools dir before the failed register.
    Before = lists:sort(filelib:wildcard(filename:join(ToolsDir, "*"))),

    %% An invalid manifest (`effect banana') is rejected before any disk write.
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_nowrite\")\n"
                 "  (effect banana) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    Reply = register_over_socket(SocketPath, Manifest),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),

    %% The tools dir is unchanged: no `<name>.lisp' was written for the rejected
    %% tool and the listing is identical to the pre-register snapshot.
    After = lists:sort(filelib:wildcard(filename:join(ToolsDir, "*"))),
    Before = After,
    [] = filelib:wildcard(filename:join(ToolsDir, "mgmt_nowrite.lisp")),
    ok.

%% Criterion 7 (#220): a failed register leaves the running registry without the
%% rejected tool. Validation (compile + normalize) runs before the tool enters
%% the live registry, so a rejected request never registers the named tool. The
%% daemon boots with an empty tools dir; the test sends a register whose manifest
%% is rejected by `normalize/1' (`effect banana'), and asserts a real
%% `soma_tool_registry:resolve_descriptor/1' for the rejected name still returns
%% `{error, not_found}' -- the tool never entered the live registry.
test_failed_register_leaves_registry_clean(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% Nothing named `mgmt_reject' is registered at boot (empty tools dir).
    {error, not_found} = soma_tool_registry:resolve_descriptor(mgmt_reject),

    %% An invalid manifest (`effect banana') is rejected before the tool enters
    %% the live registry.
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_reject\")\n"
                 "  (effect banana) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    Reply = register_over_socket(SocketPath, Manifest),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),

    %% The rejected tool never entered the live registry: a real resolve for its
    %% name still returns `not_found'.
    {error, not_found} = soma_tool_registry:resolve_descriptor(mgmt_reject),
    ok.

%% Criterion 8 (#220): a register request declaring a built-in name is rejected
%% with `{reserved_name, Name}' before any disk write or live registration. The
%% built-in set is `soma_tool_registry:builtin_names/0'; `echo' is one of them.
%% The daemon boots with an empty tools dir; the test sends a
%% `(tool-register (tool ...))' frame whose manifest declares `(name "echo")',
%% and asserts the wire reply is a failed result whose reason is the exact
%% rendering of `{reserved_name, echo}' -- the reserved-name gate fired, so the
%% built-in `echo' was never overwritten in the live registry.
test_register_builtin_name_reserved(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% `echo' is a built-in, so it is in the reserved set.
    true = lists:member(echo, soma_tool_registry:builtin_names()),

    Manifest = <<"(tool\n"
                 "  (name \"echo\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,

    %% The reserved-name reason rendered the way the server carries it on the wire.
    Expected = iolist_to_binary(soma_lisp:render({reserved_name, echo})),

    %% The daemon rejects the register with a failed result carrying the
    %% reserved-name reason verbatim.
    Reply = register_over_socket(SocketPath, Manifest),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),
    {_, _} = binary:match(Reply, Expected),
    ok.

%% Criterion 9 (#220): a register request for a name that already resolves as a
%% config tool is rejected with `{already_registered, Name}' -- the live-duplicate
%% gate, checked against the running registry, distinct from the boot loader's
%% per-load `{duplicate_name, Name}'. The daemon boots with an empty tools dir;
%% the first register for `mgmt_dup' succeeds and the name resolves live; a
%% second register for the same name is a failed result whose reason is the
%% exact rendering of `{already_registered, mgmt_dup}'.
test_register_existing_config_tool_already_registered(Config) ->
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
                 "  (name \"mgmt_dup\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,

    %% The first register succeeds: the name now resolves live as a config tool.
    FirstReply = register_over_socket(SocketPath, Manifest),
    match = re:run(FirstReply, "\\(status registered\\)", [{capture, none}]),
    {ok, #{adapter := cli}} = soma_tool_registry:resolve_descriptor(mgmt_dup),

    %% A second register for the same name is rejected with the live-duplicate
    %% reason carried verbatim on the wire.
    Expected = iolist_to_binary(soma_lisp:render({already_registered, mgmt_dup})),
    Reply = register_over_socket(SocketPath, Manifest),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),
    {_, _} = binary:match(Reply, Expected),
    ok.

%% Criterion 10 (#220): a `(tool-list)' request returns each live tool as a
%% `(tool ...)' entry carrying `name' / `effect' / `idempotent' / `adapter',
%% plus `description' only when the descriptor has one. The daemon boots with an
%% empty tools dir, then two config tools are registered over the socket -- one
%% declaring a `description', one without -- so the optional field is exercised
%% both ways. The reply lists every live tool exactly once (the five built-ins
%% plus both config tools); the two config-tool entries are pinned field for
%% field, and the built-in `echo' entry is pinned against its live descriptor.
test_list_returns_summary_fields(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% One config tool with a description, one without.
    Described = <<"(tool\n"
                  "  (name \"mgmt_described\")\n"
                  "  (description \"Uppercases text.\")\n"
                  "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                  "  (adapter cli)\n"
                  "  (executable \"/bin/echo\")\n"
                  "  (argv \"hello\"))\n">>,
    Plain = <<"(tool\n"
              "  (name \"mgmt_plain\")\n"
              "  (effect state) (idempotent false) (timeout-ms 5000)\n"
              "  (adapter cli)\n"
              "  (executable \"/bin/echo\")\n"
              "  (argv \"hello\"))\n">>,
    FirstReply = register_over_socket(SocketPath, Described),
    match = re:run(FirstReply, "\\(status registered\\)", [{capture, none}]),
    SecondReply = register_over_socket(SocketPath, Plain),
    match = re:run(SecondReply, "\\(status registered\\)", [{capture, none}]),

    Reply = request_over_socket(SocketPath, <<"(tool-list)">>),
    {ok, [['tool-list' | Entries]]} = soma_lfe_reader:read_forms(Reply),

    %% Every live tool appears exactly once: the five built-ins plus the two
    %% config tools just registered -- and every entry leads with its name.
    Names = lists:sort([Name || [tool, [name, Name] | _] <- Entries]),
    Expected = lists:sort([atom_to_binary(N, utf8)
                           || N <- soma_tool_registry:builtin_names()]
                          ++ [<<"mgmt_described">>, <<"mgmt_plain">>]),
    Expected = Names,
    true = length(Entries) =:= length(Names),

    %% The config tool with a description carries all four summary fields plus
    %% the description, pinned field for field.
    [DescribedEntry] =
        [E || [tool, [name, <<"mgmt_described">>] | _] = E <- Entries],
    [tool,
     [name, <<"mgmt_described">>],
     [effect, reader],
     [idempotent, true],
     [adapter, cli],
     [description, <<"Uppercases text.">>]] = DescribedEntry,

    %% The config tool without a description carries exactly the four summary
    %% fields -- no `description' sub-form appears.
    [PlainEntry] = [E || [tool, [name, <<"mgmt_plain">>] | _] = E <- Entries],
    [tool,
     [name, <<"mgmt_plain">>],
     [effect, state],
     [idempotent, false],
     [adapter, cli]] = PlainEntry,

    %% A built-in entry matches its live descriptor: `echo' reports its own
    %% effect / idempotent / description and the `erlang_module' adapter.
    {ok, #{effect := EchoEffect, idempotent := EchoIdempotent,
           description := EchoDescription}} =
        soma_tool_registry:resolve_descriptor(echo),
    [EchoEntry] = [E || [tool, [name, <<"echo">>] | _] = E <- Entries],
    [tool,
     [name, <<"echo">>],
     [effect, EchoEffect],
     [idempotent, EchoIdempotent],
     [adapter, erlang_module],
     [description, EchoDescription]] = EchoEntry,
    ok.

%% Criterion 11 (#220): the `(tool-list)' reply omits runtime internals --
%% `module' / `executable' / `argv' / `timeout-ms' field forms never appear,
%% and neither do pid / port / ref forms nor the registered executable path,
%% argv values, or timeout value as bytes. A cli config tool carrying a
%% distinctive executable / argv / timeout is registered first so there is a
%% descriptor with something to leak; the reply bytes are then scanned for
%% every forbidden form and value, and each parsed entry's field names are
%% checked against the safe set (name / effect / idempotent / adapter /
%% description) alone.
test_list_omits_internal_fields(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% A cli tool with a distinctive executable path, argv value, and timeout,
    %% so any leak of those internals into the list reply is detectable.
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_scrub\")\n"
                 "  (description \"Scrub check.\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 4321)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"scrub-argv-value\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),

    Reply = request_over_socket(SocketPath, <<"(tool-list)">>),

    %% Sanity: the registered tool is in the reply at all.
    {_, _} = binary:match(Reply, <<"(name \"mgmt_scrub\")">>),

    %% No internal field form appears anywhere in the reply bytes.
    nomatch = binary:match(Reply, <<"(executable">>),
    nomatch = binary:match(Reply, <<"(module">>),
    nomatch = binary:match(Reply, <<"(argv">>),
    nomatch = binary:match(Reply, <<"(timeout-ms">>),
    nomatch = binary:match(Reply, <<"(timeout_ms">>),
    nomatch = binary:match(Reply, <<"(pid">>),
    nomatch = binary:match(Reply, <<"(port">>),
    nomatch = binary:match(Reply, <<"(ref">>),
    %% The registered internals never reach the wire as values either.
    nomatch = binary:match(Reply, <<"/bin/echo">>),
    nomatch = binary:match(Reply, <<"scrub-argv-value">>),
    nomatch = binary:match(Reply, <<"4321">>),

    %% Structurally: every entry's field names come from the safe set alone.
    {ok, [['tool-list' | Entries]]} = soma_lfe_reader:read_forms(Reply),
    Allowed = [name, effect, idempotent, adapter, description],
    lists:foreach(
      fun([tool | Fields]) ->
          lists:foreach(
            fun([Key | _]) -> true = lists:member(Key, Allowed) end,
            Fields)
      end,
      Entries),
    ok.

%% Criterion 12 (#220): a `(tool-remove "<name>")' request makes a
%% config-registered tool unresolved in the running daemon. The daemon boots
%% with an empty tools dir; a config tool `mgmt_gone' is registered over the
%% socket and resolves live; the test then sends `(tool-remove "mgmt_gone")'
%% and asserts the daemon acknowledges the removal and a real
%% `soma_tool_registry:resolve_descriptor/1' on the same daemon returns
%% `{error, not_found}' -- the live registration is gone without any restart.
test_remove_config_tool_unresolved(Config) ->
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
                 "  (name \"mgmt_gone\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),
    %% The config tool resolves live before the remove.
    {ok, #{adapter := cli}} = soma_tool_registry:resolve_descriptor(mgmt_gone),

    %% The remove verb succeeds on the wire...
    Reply = request_over_socket(SocketPath, <<"(tool-remove \"mgmt_gone\")">>),
    match = re:run(Reply, "\\(status removed\\)", [{capture, none}]),

    %% ...and the name no longer resolves in the same running daemon.
    {error, not_found} = soma_tool_registry:resolve_descriptor(mgmt_gone),
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
    request_over_socket(SocketPath, Source).

%% Send one framed request over the daemon's socket and return the reply bytes.
request_over_socket(SocketPath, Source) ->
    {ok, Sock} = gen_tcp:connect({local, SocketPath}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    Reply.
