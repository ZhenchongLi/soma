%% @doc CT proofs for config-registered cli tools (#205): `(tool ...)' files
%% in a tools directory are loaded at daemon boot, compiled to manifests, and
%% registered through the same `soma_tool_registry:register_tool/1' path the
%% built-ins take. Each case boots the daemon through `soma_cli:daemon/1' with
%% a temp `socket', a temp `config_path', and a temp `tools_dir' in `Args', so
%% no layer is bypassed and nothing touches the real `~/.soma'.
-module(soma_tool_config_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_daemon_boot_registers_config_tool/1]).

all() ->
    [test_daemon_boot_registers_config_tool].

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
