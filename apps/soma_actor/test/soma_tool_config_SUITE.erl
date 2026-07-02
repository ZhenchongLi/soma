%% @doc CT proofs for config-registered cli tools (#205): `(tool ...)' files
%% in a tools directory are loaded at daemon boot, compiled to manifests, and
%% registered through the same `soma_tool_registry:register_tool/1' path the
%% built-ins take. Each case boots the daemon through `soma_cli:daemon/1' with
%% a temp `socket', a temp `config_path', and a temp `tools_dir' in `Args', so
%% no layer is bypassed and nothing touches the real `~/.soma'.
-module(soma_tool_config_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_daemon_boot_registers_config_tool/1,
         test_config_tool_description_in_catalog/1,
         test_invalid_field_surfaces_normalize_error/1,
         test_safety_defaults_and_declared_values/1,
         test_non_cli_adapter_rejected/1]).

all() ->
    [test_daemon_boot_registers_config_tool,
     test_config_tool_description_in_catalog,
     test_invalid_field_surfaces_normalize_error,
     test_safety_defaults_and_declared_values,
     test_non_cli_adapter_rejected].

init_per_testcase(_Case, Config) ->
    %% The entry point under test is `soma_cli:daemon/1', which boots the
    %% runtime itself. Stop it first so the boot -- and the fresh registry it
    %% seeds -- is observable per case.
    _ = application:stop(soma_runtime),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(soma_runtime),
    ok.

%% Criterion 1 (#205): a directory of `(tool ...)' files loaded at daemon boot
%% registers each valid tool. The test writes one valid `(tool ...)' file into
%% a temp tools dir, boots the daemon with that dir as the `tools_dir'
%% override, and asserts the declared tool name resolves through
%% `soma_tool_registry:resolve_descriptor/1' to a `cli' descriptor carrying
%% the declared executable and argv -- proving the boot path read the file,
%% compiled it to a manifest, and registered it in the running registry.
test_daemon_boot_registers_config_tool(Config) ->
    SocketPath = socket_path(Config),
    ToolsDir = tools_dir(Config),
    ToolFile = filename:join(ToolsDir, "cfg_upper.lisp"),
    ok = file:write_file(
           ToolFile,
           <<"(tool\n"
             "  (name \"cfg_upper\")\n"
             "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
             "  (adapter cli)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv \"hello\" \"world\"))\n">>),
    {ok, Resolved} = soma_cli:daemon(#{socket => SocketPath,
                                       config_path => no_llm_config_file(Config),
                                       tools_dir => ToolsDir}),
    SocketPath = Resolved,
    %% The declared name resolves in the running registry to a `cli'
    %% descriptor carrying the declared executable and argv.
    {ok, Descriptor} = soma_tool_registry:resolve_descriptor(cfg_upper),
    #{adapter := cli, executable := Executable, argv := Argv} = Descriptor,
    <<"/bin/echo">> = unicode:characters_to_binary(Executable),
    [<<"hello">>, <<"world">>] =
        [unicode:characters_to_binary(A) || A <- Argv],
    ok.

%% Criterion 2 (#205): a tool file that declares a `(description "...")'
%% appears in `soma_tool_registry:catalog/0' with that description. Entry
%% point is `soma_tool_config:load_dir/1' directly -- boot wiring is
%% criterion 1's proof; this criterion is about the description surviving the
%% loader -> register_tool -> registry state -> catalog chain.
test_config_tool_description_in_catalog(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    %% A dedicated subdir (the suite's priv_dir is shared across cases, and
    %% load_dir reads every *.lisp in the dir it is given).
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_desc"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_described.lisp"),
           <<"(tool\n"
             "  (name \"cfg_described\")\n"
             "  (description \"Uppercase the final argv argument.\")\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    #{registered := [cfg_described], skipped := []} =
        soma_tool_config:load_dir(ToolsDir),
    [Entry] = [E || #{name := cfg_described} = E
                        <- soma_tool_registry:catalog()],
    #{description := <<"Uppercase the final argv argument.">>} = Entry,
    ok.

%% Criterion 3 (#205): a tool file carrying an invalid manifest field goes
%% through `soma_tool_manifest:normalize/1' -- the same validation path as
%% built-ins -- so its skip diagnostic carries the normalize error verbatim.
%% The loader must pass the declared value through, not pre-validate it: a
%% file declaring `(effect banana)' must skip with exactly
%% `{invalid_effect, banana}', normalize's own error name.
test_invalid_field_surfaces_normalize_error(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_bad_effect"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_bad_effect.lisp"),
           <<"(tool\n"
             "  (name \"cfg_bad_effect\")\n"
             "  (effect banana)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    #{registered := [], skipped := [SkipEntry]} =
        soma_tool_config:load_dir(ToolsDir),
    #{file := "cfg_bad_effect.lisp",
      reason := {invalid_effect, banana}} = SkipEntry,
    ok.

%% Criterion 4 (#205): safety metadata defaults conservatively and declared
%% values win. A tool file declaring none of `effect' / `idempotent' /
%% `timeout-ms' registers as effect `state', idempotent `false', timeout
%% 30000 ms (never guess a tool is safe); a file declaring all three
%% registers with exactly the declared values. The resolved descriptors
%% prove both sides.
test_safety_defaults_and_declared_values(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_defaults"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    %% Declares none of the three safety fields.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_defaulted.lisp"),
           <<"(tool\n"
             "  (name \"cfg_defaulted\")\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    %% Declares all three.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_declared.lisp"),
           <<"(tool\n"
             "  (name \"cfg_declared\")\n"
             "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    #{registered := [cfg_declared, cfg_defaulted], skipped := []} =
        soma_tool_config:load_dir(ToolsDir),
    {ok, Defaulted} = soma_tool_registry:resolve_descriptor(cfg_defaulted),
    #{effect := state, idempotent := false, timeout_ms := 30000} = Defaulted,
    {ok, Declared} = soma_tool_registry:resolve_descriptor(cfg_declared),
    #{effect := reader, idempotent := true, timeout_ms := 5000} = Declared,
    ok.

%% Criterion 5 (#205): a tool file declaring any adapter other than `cli' is
%% skipped with a named diagnostic -- config files cannot inject modules. The
%% rejection is deliberately at compile stage, in front of
%% `soma_tool_manifest:normalize/1' (which would only complain about a missing
%% `module' field, and a file that declared one would pass). The skip reason
%% names the offending adapter, and the declared tool name never reaches the
%% registry.
test_non_cli_adapter_rejected(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_bad_adapter"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_module_inject.lisp"),
           <<"(tool\n"
             "  (name \"cfg_module_inject\")\n"
             "  (adapter erlang_module)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    #{registered := [], skipped := [SkipEntry]} =
        soma_tool_config:load_dir(ToolsDir),
    #{file := "cfg_module_inject.lisp",
      reason := {adapter_not_allowed, wrong_adapter_value}} = SkipEntry,
    %% The name never reached the registry.
    {error, not_found} =
        soma_tool_registry:resolve_descriptor(cfg_module_inject),
    ok.

%% A fresh temp tools directory under the case's priv_dir.
tools_dir(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "tools"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

%% An `[llm]'-less config file, so the daemon's model config resolves to the
%% mock default and never reads the real `~/.soma/config'.
no_llm_config_file(Config) ->
    File = filename:join(?config(priv_dir, Config), "no_llm.config"),
    ok = file:write_file(File, <<"# no llm table here\n">>),
    File.

%% AF_UNIX socket paths are bounded by sun_path (~104 bytes on macOS), so the
%% long CT priv_dir cannot hold a bindable socket. Use a short unique path
%% under the system temp dir; os:getpid() makes it unique across BEAM runs
%% (see soma_cli_server_SUITE for the full rationale), and the pre-delete
%% clears any leftover at the unique path.
socket_path(_Config) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_tcfg_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
