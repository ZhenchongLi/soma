%% @doc CT proofs for the socket tool-management verbs (#220): `soma tool
%% register|list|remove'. The client-side wire cases (a verb renders and sends
%% the right s-expr over the socket) use `soma_cli_request_capture' standing in
%% for the daemon so the test reads the exact bytes sent. The server-side cases
%% boot a real daemon over a temp socket + tools dir.
-module(soma_tool_management_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").

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
         test_remove_config_tool_unresolved/1,
         test_remove_deletes_only_owned_manifest_file/1,
         test_remove_builtin_not_config_tool/1,
         test_remove_never_deletes_outside_tools_dir/1,
         test_restart_after_remove_stays_unresolved/1,
         test_register_appends_bounded_event/1,
         test_remove_appends_bounded_event/1,
         test_tool_events_omit_sensitive_fields/1,
         test_register_starts_no_actor_task/1,
         test_harness_drives_real_socket_with_temp_dirs_and_stub/1,
         test_register_into_missing_tools_dir_creates_it/1,
         test_cli_client_tool_list_and_remove_reach_daemon/1,
         test_register_missing_cli_fields_replies_error_no_crash/1,
         test_remove_undeletable_manifest_replies_error_keeps_tool/1,
         test_restart_after_register_with_params_resolves_placeholder_tool/1]).

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
     test_remove_config_tool_unresolved,
     test_remove_deletes_only_owned_manifest_file,
     test_remove_builtin_not_config_tool,
     test_remove_never_deletes_outside_tools_dir,
     test_restart_after_remove_stays_unresolved,
     test_register_appends_bounded_event,
     test_remove_appends_bounded_event,
     test_tool_events_omit_sensitive_fields,
     test_register_starts_no_actor_task,
     test_harness_drives_real_socket_with_temp_dirs_and_stub,
     test_register_into_missing_tools_dir_creates_it,
     test_cli_client_tool_list_and_remove_reach_daemon,
     test_register_missing_cli_fields_replies_error_no_crash,
     test_remove_undeletable_manifest_replies_error_keeps_tool,
     test_restart_after_register_with_params_resolves_placeholder_tool].

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
    %% A per-case stub executable, so cli-tool cases never depend on a shared
    %% location or a system binary.
    Stub = filename:join(Base, "stub_tool"),
    ok = file:write_file(Stub, <<"#!/bin/sh\nprintf 'stub-ok'\n">>),
    ok = file:change_mode(Stub, 8#755),
    [{base_dir, Base}, {socket_path, SocketPath}, {stub_executable, Stub}
     | Config].

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
    {ok, #{name := <<"mgmt_writer">>, adapter := cli}} =
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

%% Dogfooding regression (docmod integration, 2026-07-02): `render_tool_manifest/1'
%% dropped a manifest's `params' entirely, so ANY templated tool (argv carrying
%% `{name}' placeholders, #218) silently failed to reload after a restart --
%% `load_dir/1' saw an argv placeholder with no matching declared param and
%% skipped the file with `{unknown_argv_placeholder, _}'. This is exactly the
%% shape a real cli tool with multi-arg argv (e.g. docmod's `edit <doc>
%% <changes>') needs. Register a templated tool, restart, and assert it still
%% resolves with its params and argv intact -- not skipped.
test_restart_after_register_with_params_resolves_placeholder_tool(Config) ->
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
                 "  (name \"mgmt_placeholder_reboot\")\n"
                 "  (effect state) (idempotent false) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"edit\" \"{doc}\" \"{changes}\")\n"
                 "  (params ((\"doc\" string required \"Document path\")\n"
                 "           (\"changes\" string required \"Changes path\"))))\n">>,
    Reply = register_over_socket(SocketPath, Manifest),
    match = re:run(Reply, "\\(status registered\\)", [{capture, none}]),
    {ok, LiveDescriptor} =
        soma_tool_registry:resolve_descriptor(mgmt_placeholder_reboot),
    #{params := LiveParams} = LiveDescriptor,
    2 = length(LiveParams),

    _ = stop_over_socket(SocketPath),
    ok = wait_socket_gone(SocketPath, 50),
    _ = application:stop(soma_runtime),

    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% Before the fix this resolved `{error, not_found}': `load_dir/1' skipped
    %% the file because the persisted manifest had lost its `params', so the
    %% argv placeholders no longer named a declared param.
    {ok, RebootDescriptor} =
        soma_tool_registry:resolve_descriptor(mgmt_placeholder_reboot),
    #{argv := [<<"edit">>, <<"{doc}">>, <<"{changes}">>],
      params := RebootParams} = RebootDescriptor,
    2 = length(RebootParams),
    ParamNames = lists:sort([Name || #{name := Name} <- RebootParams]),
    [<<"changes">>, <<"doc">>] = ParamNames,
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
%% exact rendering of `{already_registered, <<"mgmt_dup">>}'.
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
    Expected = iolist_to_binary(
                 soma_lisp:render(
                   {already_registered, <<"mgmt_dup">>})),
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

%% Criterion 13 (#220): a successful remove deletes only the manifest file
%% owned by the configured tools directory -- `<tools_dir>/<name>.lisp', a path
%% built from the configured dir plus the tool name as a basename. The daemon
%% boots with an empty tools dir; a config tool `mgmt_delfile' is registered
%% over the socket (writing `mgmt_delfile.lisp'), and an unrelated neighbour
%% file is placed alongside it in the tools dir. After a successful
%% `(tool-remove "mgmt_delfile")' the tool's own manifest file is gone while
%% the neighbour file is still present byte-for-byte -- the delete touched
%% exactly the one owned file.
test_remove_deletes_only_owned_manifest_file(Config) ->
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
                 "  (name \"mgmt_delfile\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),
    %% The register persisted the tool's own manifest file.
    ManifestFile = filename:join(ToolsDir, "mgmt_delfile.lisp"),
    true = filelib:is_regular(ManifestFile),

    %% An unrelated neighbour file sits in the same tools dir (written after
    %% boot, so it is a plain file -- never a registered tool).
    NeighbourFile = filename:join(ToolsDir, "neighbour.lisp"),
    NeighbourBytes = <<"; unrelated neighbour -- must survive the remove\n">>,
    ok = file:write_file(NeighbourFile, NeighbourBytes),

    %% The remove succeeds on the wire...
    Reply = request_over_socket(SocketPath, <<"(tool-remove \"mgmt_delfile\")">>),
    match = re:run(Reply, "\\(status removed\\)", [{capture, none}]),

    %% ...the tool's own `<name>.lisp' is gone from the tools dir...
    false = filelib:is_regular(ManifestFile),
    {error, enoent} = file:read_file(ManifestFile),

    %% ...and the unrelated neighbour file survives byte-for-byte.
    {ok, NeighbourBytes} = file:read_file(NeighbourFile),
    ok.

%% Criterion 14 (#220): a `(tool-remove "<name>")' request for a built-in tool
%% is rejected with `{not_config_tool, Name}' -- a removable name must be a
%% live *config* tool, and a built-in is not one. `echo' is a built-in, so
%% removing it is a failed result whose reason is the exact rendering of
%% `{not_config_tool, echo}' -- the name as the existing built-in atom, the
%% same way the register gates carry `{reserved_name, echo}'. The built-in
%% survives the rejected remove: `echo' still resolves on the same daemon.
test_remove_builtin_not_config_tool(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% `echo' is a built-in and resolves live before the remove attempt.
    true = lists:member(echo, soma_tool_registry:builtin_names()),
    {ok, _Builtin} = soma_tool_registry:resolve_descriptor(echo),

    %% The daemon rejects the remove with a failed result carrying the
    %% not-config-tool reason -- the built-in atom name -- verbatim.
    Expected = iolist_to_binary(soma_lisp:render({not_config_tool, echo})),
    Reply = request_over_socket(SocketPath, <<"(tool-remove \"echo\")">>),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),
    {_, _} = binary:match(Reply, Expected),

    %% The built-in was never unregistered: `echo' still resolves.
    {ok, _StillThere} = soma_tool_registry:resolve_descriptor(echo),
    ok.

%% Criterion 15 (#220): a remove request never deletes a path outside the
%% configured tools directory. The remove handler maps the wire name to an
%% *existing* live config-tool atom and builds the delete path from the
%% configured dir plus that atom as a basename -- so a traversal-shaped name
%% (`../sentinel', or an absolute path, which `filename:join/2' would let
%% replace the tools dir entirely) matches no config tool and is rejected
%% before any deletion. A sentinel file placed one level above the tools dir
%% -- exactly where a naive `filename:join(ToolsDir, Name ++ ".lisp")' would
%% land for `../sentinel' -- survives both attempts byte-for-byte.
test_remove_never_deletes_outside_tools_dir(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% The sentinel sits outside the tools dir, at the exact path a naive
    %% basename-less join would delete for the name `../sentinel'.
    SentinelFile = filename:join(?config(base_dir, Config), "sentinel.lisp"),
    SentinelBytes = <<"; outside the tools dir -- must survive any remove\n">>,
    ok = file:write_file(SentinelFile, SentinelBytes),

    %% A relative traversal name matches no live config tool: rejected, never
    %% acknowledged as removed.
    RelReply = request_over_socket(SocketPath,
                                   <<"(tool-remove \"../sentinel\")">>),
    match = re:run(RelReply, "\\(status error\\)", [{capture, none}]),
    nomatch = re:run(RelReply, "\\(status removed\\)", [{capture, none}]),

    %% An absolute-path name is rejected the same way.
    AbsName = filename:rootname(SentinelFile),
    AbsReply = request_over_socket(
                 SocketPath,
                 iolist_to_binary(["(tool-remove \"", AbsName, "\")"])),
    match = re:run(AbsReply, "\\(status error\\)", [{capture, none}]),
    nomatch = re:run(AbsReply, "\\(status removed\\)", [{capture, none}]),

    %% The sentinel outside the tools dir survives byte-for-byte.
    {ok, SentinelBytes} = file:read_file(SentinelFile),
    ok.

%% Criterion 16 (#220): a daemon restart after a remove keeps the removed tool
%% unresolved -- the remove's file deletion is the durable half of the verb, so
%% the boot loader finds no manifest to re-register. The daemon boots with an
%% empty tools dir; a config tool `mgmt_purged' is registered over the socket
%% (persisting `mgmt_purged.lisp') and then removed (deleting that file). The
%% daemon is stopped and the runtime reset -- if the remove had only touched the
%% live registry, the reboot's `soma_tool_config:load_dir/1' would re-register
%% the leftover file. After a fresh `soma_cli:daemon/1' boot against the same
%% tools dir, the name still does not resolve: the removal survived the restart.
test_restart_after_remove_stays_unresolved(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    %% First boot: register a config tool, then remove it over the socket.
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_purged\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),
    {ok, #{adapter := cli}} = soma_tool_registry:resolve_descriptor(mgmt_purged),
    Reply = request_over_socket(SocketPath, <<"(tool-remove \"mgmt_purged\")">>),
    match = re:run(Reply, "\\(status removed\\)", [{capture, none}]),

    %% Stop the daemon and reset the runtime, so only what is on disk decides
    %% what the reboot registers.
    _ = stop_over_socket(SocketPath),
    ok = wait_socket_gone(SocketPath, 50),
    _ = application:stop(soma_runtime),

    %% Reboot against the same tools dir: `load_dir/1' finds no manifest file
    %% for the removed tool, so the name stays unresolved.
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    {error, not_found} = soma_tool_registry:resolve_descriptor(mgmt_purged),
    ok.

%% Criterion 17 (#220): a successful register appends exactly one bounded
%% `tool.registered' event through `soma_event_store:append/2'. The daemon
%% boots with an empty tools dir, so the store holds no `tool.registered'
%% event yet; after a valid register over the socket exactly one appears. It
%% is bounded per the design: `append/2' fills the run/session/step ids with
%% `undefined' (tool management belongs to no run), and the payload carries
%% the tool name and the safe metadata alone -- `effect' / `idempotent' /
%% `adapter' -- pinned as the exact key set so nothing else can ride along.
test_register_appends_bounded_event(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    Store = runtime_event_store_pid(),
    %% No `tool.registered' event exists before the register.
    [] = tool_registered_events(Store),

    Manifest = <<"(tool\n"
                 "  (name \"mgmt_event\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),

    %% Exactly one `tool.registered' event was appended...
    [Event] = tool_registered_events(Store),
    %% ...with the run/session/step ids `undefined' (filled by `append/2' --
    %% tool management belongs to no run)...
    #{run_id := undefined, session_id := undefined, step_id := undefined,
      payload := Payload} = Event,
    %% ...and a bounded payload: the tool name plus the safe metadata, and
    %% nothing else.
    #{tool_name := <<"mgmt_event">>, effect := reader, idempotent := true,
      adapter := cli} = Payload,
    [adapter, effect, idempotent, tool_name] = lists:sort(maps:keys(Payload)),
    ok.

%% Criterion 18 (#220): a successful remove appends exactly one bounded
%% `tool.removed' event through `soma_event_store:append/2' -- the remove-side
%% twin of criterion 17. The daemon boots with an empty tools dir; a config
%% tool is registered (which appends no `tool.removed' event) and then removed
%% over the socket, after which exactly one `tool.removed' event appears. It
%% is bounded the same way the register event is: `append/2' fills the
%% run/session/step ids with `undefined' (tool management belongs to no run),
%% and the payload carries the removed tool's name alone -- pinned as the
%% exact key set so nothing else can ride along.
test_remove_appends_bounded_event(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    Store = runtime_event_store_pid(),
    %% No `tool.removed' event exists before anything happens.
    [] = tool_removed_events(Store),

    Manifest = <<"(tool\n"
                 "  (name \"mgmt_rm_event\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),
    %% The register alone appends no `tool.removed' event.
    [] = tool_removed_events(Store),

    Reply = request_over_socket(SocketPath, <<"(tool-remove \"mgmt_rm_event\")">>),
    match = re:run(Reply, "\\(status removed\\)", [{capture, none}]),

    %% Exactly one `tool.removed' event was appended...
    [Event] = tool_removed_events(Store),
    %% ...with the run/session/step ids `undefined' (filled by `append/2' --
    %% tool management belongs to no run)...
    #{run_id := undefined, session_id := undefined, step_id := undefined,
      payload := Payload} = Event,
    %% ...and a bounded payload: the removed tool's name, and nothing else.
    #{tool_name := <<"mgmt_rm_event">>} = Payload,
    [tool_name] = lists:sort(maps:keys(Payload)),
    ok.

%% Criterion 19 (#220): tool-management events omit executable paths, argv
%% values, pids, ports, and refs. A cli tool carrying a distinctive executable
%% path / argv value / timeout is registered and then removed, so both the
%% `tool.registered' and the `tool.removed' event exist with something to
%% leak. Each stored event is then checked three ways: a deep term scan finds
%% no pid / port / ref / fun anywhere in the event; the payload carries none
%% of the internal field keys (`executable' / `argv' / `module' /
%% `timeout_ms'); and the registered internals never appear in the payload's
%% rendered bytes as values either.
test_tool_events_omit_sensitive_fields(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    Store = runtime_event_store_pid(),

    %% Distinctive executable path, argv value, and timeout, so any leak of
    %% those internals into a stored event is detectable as bytes.
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_ev_scrub\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 4321)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"scrub-argv-value\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),
    Reply = request_over_socket(SocketPath, <<"(tool-remove \"mgmt_ev_scrub\")">>),
    match = re:run(Reply, "\\(status removed\\)", [{capture, none}]),

    %% Both tool-management events exist -- the register one and the remove one.
    [RegEvent] = tool_registered_events(Store),
    [RmEvent] = tool_removed_events(Store),

    lists:foreach(
      fun(#{payload := Payload} = Event) ->
          %% No pid, port, ref, or fun anywhere in the stored event term.
          [] = sensitive_terms(Event),
          %% No internal field key rides in the payload.
          false = maps:is_key(executable, Payload),
          false = maps:is_key(argv, Payload),
          false = maps:is_key(module, Payload),
          false = maps:is_key(timeout_ms, Payload),
          %% The registered internals never appear as payload bytes either.
          Rendered = iolist_to_binary(io_lib:format("~0p", [Payload])),
          nomatch = binary:match(Rendered, <<"/bin/echo">>),
          nomatch = binary:match(Rendered, <<"scrub-argv-value">>),
          nomatch = binary:match(Rendered, <<"4321">>)
      end,
      [RegEvent, RmEvent]),
    ok.

%% Criterion 20 (#220): a `soma tool register' socket request completes without
%% starting a `soma_actor' task -- the register handler runs inline in the
%% connection handler, off the actor path (`soma_actor_sup:start_actor/1' is the
%% ask verb's entry, never register's). The daemon boots with an empty tools
%% dir; the test snapshots the live actor instances under
%% `soma_actor_child_sup' (the dynamic supervisor every started actor lands
%% under), performs a full successful register over the socket, and compares
%% the actor population afterwards.
test_register_starts_no_actor_task(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    %% Bring the actor supervisor up (as the standalone daemon boot does for
    %% the ask path), so an actor started by the register would be observable.
    case soma_actor_sup:start_link() of
        {ok, _ActorSup} -> ok;
        {error, {already_started, _ActorSup}} -> ok
    end,
    true = is_pid(whereis(soma_actor_child_sup)),
    ActorsBefore = actor_task_pids(),

    Manifest = <<"(tool\n"
                 "  (name \"mgmt_no_actor\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),

    %% The register completed inline in the connection handler: no actor task
    %% was started, so the live actor population is unchanged.
    ActorsAfter = actor_task_pids(),
    [] = ActorsAfter -- ActorsBefore,
    ActorsBefore = ActorsAfter,
    ok.

%% Criterion 21 (#220): the tool-management cases drive the real socket surface
%% with per-case temp tools directories and stub executables -- the harness
%% invariant itself. `init_per_testcase' builds a fresh temp base dir for every
%% case and writes an executable stub program into it, so no case ever needs a
%% shared location or a system binary. This case proves the invariant end to
%% end: the stub the harness provides is a real executable file living inside
%% the same per-case temp dir as the socket path; a real daemon boots on that
%% temp socket with a per-case temp tools dir; and a register over the real
%% socket lands the stub-backed tool in the live registry with the harness
%% stub as its executable.
test_harness_drives_real_socket_with_temp_dirs_and_stub(Config) ->
    _ = application:stop(soma_runtime),
    Base = ?config(base_dir, Config),
    SocketPath = ?config(socket_path, Config),
    %% The harness provides a per-case stub executable in Config...
    Stub = ?config(stub_executable, Config),
    true = is_list(Stub),
    %% ...that lives inside the same per-case temp dir as the socket path --
    %% nothing points at a shared location.
    true = filelib:is_dir(Base),
    Base = filename:dirname(SocketPath),
    Base = filename:dirname(Stub),
    %% The stub is a real file with the executable bit set.
    true = filelib:is_regular(Stub),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Stub),
    true = (Mode band 8#111) =/= 0,

    %% A real daemon boots on the temp socket with a per-case temp tools dir...
    ToolsDir = filename:join(Base, "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(Base, "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),

    %% ...and a register over the real socket lands a tool whose executable is
    %% the harness stub -- not a system binary -- in the live registry.
    Manifest = iolist_to_binary(
                 ["(tool\n"
                  "  (name \"mgmt_stub_backed\")\n"
                  "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                  "  (adapter cli)\n"
                  "  (executable \"", Stub, "\")\n"
                  "  (argv \"hello\"))\n"]),
    RegReply = register_over_socket(SocketPath, Manifest),
    match = re:run(RegReply, "\\(status registered\\)", [{capture, none}]),
    {ok, #{adapter := cli, executable := Executable}} =
        soma_tool_registry:resolve_descriptor(mgmt_stub_backed),
    StubBin = unicode:characters_to_binary(Stub),
    StubBin = unicode:characters_to_binary(Executable),
    ok.

%% The live actor instances under the dynamic actor supervisor, as pids.
actor_task_pids() ->
    lists:sort([Pid || {_Id, Pid, _Type, _Mods}
                       <- supervisor:which_children(soma_actor_child_sup),
                       is_pid(Pid)]).

%% Every pid / port / reference / fun found anywhere inside a term -- the
%% process-local values a stored event must never carry.
sensitive_terms(Term) when is_map(Term) ->
    lists:append([sensitive_terms(T)
                  || T <- maps:keys(Term) ++ maps:values(Term)]);
sensitive_terms(Term) when is_list(Term) ->
    lists:append([sensitive_terms(T) || T <- Term]);
sensitive_terms(Term) when is_tuple(Term) ->
    lists:append([sensitive_terms(T) || T <- tuple_to_list(Term)]);
sensitive_terms(Term) when is_pid(Term); is_port(Term);
                           is_reference(Term); is_function(Term) ->
    [Term];
sensitive_terms(_Term) ->
    [].

%% The runtime's supervised event store -- the same pid the server handlers
%% locate -- read directly so the test counts stored events, not wire bytes.
runtime_event_store_pid() ->
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, supervisor:which_children(soma_sup)),
    Pid.

%% Every stored `tool.registered' event, oldest first.
tool_registered_events(Store) ->
    [E || E <- soma_event_store:all(Store),
          maps:get(event_type, E, undefined) =:= <<"tool.registered">>].

%% Every stored `tool.removed' event, oldest first.
tool_removed_events(Store) ->
    [E || E <- soma_event_store:all(Store),
          maps:get(event_type, E, undefined) =:= <<"tool.removed">>].

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
%% Review finding (#220): on a fresh install nothing has created the tools
%% dir yet. A register must not crash the handler and must not leave a
%% live-only registration -- the daemon creates the directory, persists the
%% file FIRST, then registers, and replies `registered'. Boot the daemon with
%% a tools dir path that does not exist and register through the real socket.
test_register_into_missing_tools_dir_creates_it(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "never_created_tools"),
    false = filelib:is_dir(ToolsDir),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    Manifest = <<"(tool\n"
                 "  (name \"mgmt_freshdir\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    Reply = register_over_socket(SocketPath, Manifest),
    {match, _} = re:run(Reply, <<"registered">>),
    %% The manifest file exists on disk (persisted, not live-only) and the
    %% tool resolves in the running registry.
    true = filelib:is_regular(filename:join(ToolsDir, "mgmt_freshdir.lisp")),
    {ok, #{adapter := cli}} =
        soma_tool_registry:resolve_descriptor(mgmt_freshdir),
    ok.

%% Review finding (#220): the list and remove verbs must be reachable through
%% the client layer the `soma tool <verb>' commands drive -- not only by
%% hand-rolled socket frames. `soma_cli:tool_list/1' returns the catalog
%% projection reply and exit code 0; `soma_cli:tool_remove/1' removes a
%% config-registered tool so it stops resolving.
test_cli_client_tool_list_and_remove_reach_daemon(Config) ->
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
                 "  (name \"mgmt_client_verbs\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    _ = register_over_socket(SocketPath, Manifest),
    {ok, _} = soma_tool_registry:resolve_descriptor(mgmt_client_verbs),
    %% The real client verbs, exactly as `soma tool list' / `soma tool remove'
    %% dispatch them.
    0 = soma_cli:tool_list(#{socket => SocketPath}),
    0 = soma_cli:tool_remove(#{name => "mgmt_client_verbs",
                               socket => SocketPath}),
    {error, not_found} =
        soma_tool_registry:resolve_descriptor(mgmt_client_verbs),
    ok.

%% Review finding (#220, round 2): a register whose manifest omits the cli
%% fields (`executable' / `argv') must be a clean normalize-error reply --
%% never a `function_clause' in the file renderer that kills the handler and
%% closes the socket with no reply. `compile_form/1' requires only `name', so
%% the handler must run `normalize/1' before touching disk. The daemon keeps
%% serving afterwards, the tools dir stays empty, and nothing registers.
test_register_missing_cli_fields_replies_error_no_crash(Config) ->
    _ = application:stop(soma_runtime),
    SocketPath = ?config(socket_path, Config),
    ToolsDir = filename:join(?config(base_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ConfigPath = filename:join(?config(base_dir, Config), "no_llm.config"),
    ok = file:write_file(ConfigPath, <<"# no llm table here\n">>),
    {ok, SocketPath} = soma_cli:daemon(#{socket => SocketPath,
                                         config_path => ConfigPath,
                                         tools_dir => ToolsDir}),
    Reply = register_over_socket(SocketPath, <<"(tool (name \"crashcase\"))">>),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),
    %% Nothing was written, nothing registered, no crash-shaped fallout.
    [] = filelib:wildcard(filename:join(ToolsDir, "*.lisp")),
    {error, not_found} = soma_tool_registry:resolve_descriptor(crashcase),
    %% The daemon still serves: a follow-up request on a fresh connection
    %% gets a reply instead of a closed socket.
    ListReply = request_over_socket(SocketPath, <<"(tool-list)">>),
    {ok, [['tool-list' | _]]} = soma_lfe_reader:read_forms(ListReply),
    ok.

%% Review finding (#220, round 2): a remove whose manifest file cannot be
%% deleted (here: a read-only tools dir) must reply with a named error and
%% leave the live registration in place -- never reply `removed' while the
%% surviving file would re-register the tool at the next boot. Only `enoent'
%% is a tolerable delete outcome.
test_remove_undeletable_manifest_replies_error_keeps_tool(Config) ->
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
                 "  (name \"mgmt_undeletable\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\"))\n">>,
    _ = register_over_socket(SocketPath, Manifest),
    ManifestFile = filename:join(ToolsDir, "mgmt_undeletable.lisp"),
    true = filelib:is_regular(ManifestFile),
    %% Make the file undeletable: deleting a directory entry needs write
    %% permission on the DIRECTORY, so a read-only tools dir forces eacces.
    ok = file:change_mode(ToolsDir, 8#500),
    Reply = request_over_socket(SocketPath,
                                <<"(tool-remove \"mgmt_undeletable\")">>),
    ok = file:change_mode(ToolsDir, 8#755),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),
    match = re:run(Reply, "manifest_delete_failed", [{capture, none}]),
    %% Live and durable state stayed consistent: the tool still resolves and
    %% its file is still on disk.
    {ok, _} = soma_tool_registry:resolve_descriptor(mgmt_undeletable),
    true = filelib:is_regular(ManifestFile),
    ok.

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
