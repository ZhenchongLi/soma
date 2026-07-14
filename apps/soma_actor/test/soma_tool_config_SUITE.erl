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
         test_load_dir_registers_cli_tool_with_argv_placeholders/1,
         test_load_dir_skips_cli_tool_with_unknown_argv_placeholder/1,
         test_invalid_field_surfaces_normalize_error/1,
         test_safety_defaults_and_declared_values/1,
         test_non_cli_adapter_rejected/1,
         test_broken_file_skipped_daemon_serves/1,
         test_non_ascii_and_invalid_utf8_files/1,
         test_missing_or_empty_dir_boot_unchanged/1,
         test_config_tool_runs_end_to_end/1,
         test_reserved_name_skipped_builtin_and_neighbour_intact/1,
         test_shadowed_file_write_keeps_resume_safety_fields/1,
         test_duplicate_name_first_sorted_file_wins/1,
         test_docmod_example_manifests_normalize_with_expected_metadata/1]).

%% Logger handler callback (the boot-log capture used by
%% test_broken_file_skipped_daemon_serves).
-export([log/2]).

all() ->
    [test_daemon_boot_registers_config_tool,
     test_config_tool_description_in_catalog,
     test_load_dir_registers_cli_tool_with_argv_placeholders,
     test_load_dir_skips_cli_tool_with_unknown_argv_placeholder,
     test_invalid_field_surfaces_normalize_error,
     test_safety_defaults_and_declared_values,
     test_non_cli_adapter_rejected,
     test_broken_file_skipped_daemon_serves,
     test_non_ascii_and_invalid_utf8_files,
     test_missing_or_empty_dir_boot_unchanged,
     test_config_tool_runs_end_to_end,
     test_reserved_name_skipped_builtin_and_neighbour_intact,
     test_shadowed_file_write_keeps_resume_safety_fields,
     test_duplicate_name_first_sorted_file_wins,
     test_docmod_example_manifests_normalize_with_expected_metadata].

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

%% Criterion 3 (#218): `soma_tool_config:load_dir/1' compiles a config
%% `(tool ...)' file with literal cli argv placeholders plus matching
%% model-facing params, registers it through `soma_tool_registry:register_tool/1',
%% and therefore through `soma_tool_manifest:normalize/1'. The resolved
%% descriptor proves the loader did not strip or pre-render the placeholder
%% argv entries, and that the matching params reached the manifest validator.
test_load_dir_registers_cli_tool_with_argv_placeholders(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_argv_placeholders"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_doc_edit.lisp"),
           <<"(tool\n"
             "  (name \"cfg_doc_edit\")\n"
             "  (description \"Edit a document with an explicit change set.\")\n"
             "  (effect state) (idempotent false) (timeout-ms 5000)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv \"edit\" \"{doc}\" \"{changes}\")\n"
             "  (params ((\"doc\" string required \"Document path\")\n"
             "           (\"changes\" string required \"Requested edits\"))))\n">>),
    #{registered := [cfg_doc_edit], skipped := []} =
        soma_tool_config:load_dir(ToolsDir),
    {ok, Descriptor} = soma_tool_registry:resolve_descriptor(cfg_doc_edit),
    #{adapter := cli, argv := Argv, params := Params} = Descriptor,
    [<<"edit">>, <<"{doc}">>, <<"{changes}">>] =
        [unicode:characters_to_binary(A) || A <- Argv],
    [#{name := <<"doc">>, type := string, required := true,
       doc := <<"Document path">>},
     #{name := <<"changes">>, type := string, required := true,
       doc := <<"Requested edits">>}] = Params,
    ok.

%% Criterion 4 (#218): `soma_tool_config:load_dir/1' skips a config
%% `(tool ...)' file whose cli argv placeholder has no matching model-facing
%% param. The loader owns skip reporting, but the reason must be
%% `soma_tool_manifest:normalize/1''s named placeholder error.
test_load_dir_skips_cli_tool_with_unknown_argv_placeholder(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config),
                             "tools_unknown_argv_placeholder"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_bad_doc_edit.lisp"),
           <<"(tool\n"
             "  (name \"cfg_bad_doc_edit\")\n"
             "  (description \"Edit a document with an explicit change set.\")\n"
             "  (effect state) (idempotent false) (timeout-ms 5000)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv \"edit\" \"{doc}\" \"{changes}\")\n"
             "  (params ((\"doc\" string required \"Document path\"))))\n">>),
    #{registered := [], skipped := [SkipEntry]} =
        soma_tool_config:load_dir(ToolsDir),
    #{file := "cfg_bad_doc_edit.lisp",
      reason := {unknown_argv_placeholder, <<"changes">>}} = SkipEntry,
    {error, not_found} =
        soma_tool_registry:resolve_descriptor(cfg_bad_doc_edit),
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
      reason := {adapter_not_allowed, erlang_module}} = SkipEntry,
    %% The name never reached the registry.
    {error, not_found} =
        soma_tool_registry:resolve_descriptor(cfg_module_inject),
    ok.

%% Criterion 6 (#205): a file that fails to parse, compile, or normalize is
%% skipped with a named, bounded diagnostic while the remaining valid tool
%% files still register and the daemon serves requests. Entry point is
%% `soma_cli:daemon/1' -- no layer bypassed, because the criterion is about
%% boot surviving. The tools dir mixes an unparseable file, an
%% invalid-manifest file, and a valid file; the boot-time skip diagnostics
%% (one `logger:warning' per skipped file) are captured with a suite-local
%% logger handler, since `daemon/1' deliberately discards the loader's
%% result rather than letting it block boot.
test_broken_file_skipped_daemon_serves(Config) ->
    SocketPath = socket_path(Config),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_mixed"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    %% Unparseable: an unbalanced form the reader cannot parse.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_unparseable.lisp"),
           <<"(tool (name \"cfg_unparseable\"">>),
    %% Parses and compiles, but fails `soma_tool_manifest:normalize/1'.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_bad_manifest.lisp"),
           <<"(tool\n"
             "  (name \"cfg_bad_manifest\")\n"
             "  (effect banana)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    %% Valid: must register despite its broken neighbours.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_survivor.lisp"),
           <<"(tool\n"
             "  (name \"cfg_survivor\")\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    ok = logger:add_handler(soma_tool_config_suite_capture, ?MODULE,
                            #{config => #{pid => self()}}),
    try
        {ok, SocketPath} =
            soma_cli:daemon(#{socket => SocketPath,
                              config_path => no_llm_config_file(Config),
                              tools_dir => ToolsDir}),
        %% The valid tool registered through the boot path.
        {ok, #{adapter := cli}} =
            soma_tool_registry:resolve_descriptor(cfg_survivor),
        %% The broken files never reached the registry.
        {error, not_found} =
            soma_tool_registry:resolve_descriptor(cfg_unparseable),
        {error, not_found} =
            soma_tool_registry:resolve_descriptor(cfg_bad_manifest),
        %% Each skipped file produced a named, bounded boot diagnostic.
        {parse_error, [_ | _]} = receive_skip("cfg_unparseable.lisp"),
        {invalid_effect, banana} = receive_skip("cfg_bad_manifest.lisp"),
        %% And the daemon serves requests over the socket.
        0 = soma_cli:ping(#{socket => SocketPath})
    after
        _ = logger:remove_handler(soma_tool_config_suite_capture)
    end,
    ok.

%% Review finding (#205): the two non-ASCII input classes a user's editor
%% will produce must not crash the loader. Valid UTF-8 above code point 255
%% (an em-dash, Chinese text) is *valid input* — it registers with the
%% description intact in the catalog; invalid UTF-8 bytes (a Latin-1-saved
%% file) skip with the reader's named diagnostic while the valid neighbour
%% still registers. Before the reader fix both classes crashed
%% `soma_lfe_reader:read_forms/1` and took `load_dir/1` — and daemon boot —
%% down with them.
test_non_ascii_and_invalid_utf8_files(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_unicode"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    %% Valid UTF-8, code points above 255 in the description.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_unicode.lisp"),
           <<"(tool\n"
             "  (name \"cfg_unicode\")\n"
             "  (description \"Résumé formatter — 大写\")\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n"/utf8>>),
    %% Invalid UTF-8 bytes inside the file.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_latin1.lisp"),
           <<"(tool (name \"cfg_latin1", 16#ff, 16#fe, "\"))">>),
    #{registered := [cfg_unicode], skipped := [SkipEntry]} =
        soma_tool_config:load_dir(ToolsDir),
    %% The non-ASCII description survived the whole chain into the catalog.
    [#{description := <<"Résumé formatter — 大写"/utf8>>}] =
        [E || #{name := cfg_unicode} = E <- soma_tool_registry:catalog()],
    %% The invalid-UTF-8 file skipped with the reader's named diagnostic.
    #{file := "cfg_latin1.lisp",
      reason := {parse_error,
                 [#{message := <<"source is not valid UTF-8">>}]}} =
        SkipEntry,
    ok.

%% Criterion 7 (#205): a missing or empty tools directory leaves daemon boot
%% byte-for-byte unchanged. Entry point is `soma_cli:daemon/1' with a
%% `tools_dir' pointing at a path that does not exist: after boot the running
%% registry holds exactly the built-in seed (no extra name, no missing name),
%% no skip log line was emitted (same capture handler as criterion 6), and
%% the daemon answers a ping. `soma_tool_config:load_dir/1' is then called
%% directly on the missing path and on an empty directory to pin the empty
%% result -- `#{registered => [], skipped => []}' -- and the registry is
%% re-checked to prove neither call touched it.
test_missing_or_empty_dir_boot_unchanged(Config) ->
    SocketPath = socket_path(Config),
    PrivDir = ?config(priv_dir, Config),
    %% Deliberately never created.
    MissingDir = filename:join(PrivDir, "tools_nonexistent"),
    false = filelib:is_dir(MissingDir),
    ok = logger:add_handler(soma_tool_config_suite_no_skip, ?MODULE,
                            #{config => #{pid => self()}}),
    try
        {ok, SocketPath} =
            soma_cli:daemon(#{socket => SocketPath,
                              config_path => no_llm_config_file(Config),
                              tools_dir => MissingDir}),
        %% The registered tool names equal the built-in seed exactly.
        SeedNames = [echo, fail, file_read, file_write, sleep, text_grep,
                     text_head],
        SeedNames = registered_names(),
        %% The loader returns the empty result for the missing path and for
        %% an empty directory -- no skip entry, nothing registered.
        Empty = #{registered => [], skipped => []},
        Empty = soma_tool_config:load_dir(MissingDir),
        EmptyDir = filename:join(PrivDir, "tools_empty"),
        ok = filelib:ensure_dir(filename:join(EmptyDir, "x")),
        Empty = soma_tool_config:load_dir(EmptyDir),
        %% Neither call touched the registry.
        SeedNames = registered_names(),
        %% No skip diagnostic was logged anywhere along the way.
        receive
            {tool_skip, File, Reason} ->
                ct:fail({unexpected_skip_diagnostic, File, Reason})
        after 0 -> ok
        end,
        %% And the daemon serves requests over the socket.
        0 = soma_cli:ping(#{socket => SocketPath})
    after
        _ = logger:remove_handler(soma_tool_config_suite_no_skip)
    end,
    ok.

%% Criterion 8 (#205): a run whose step names a config-registered tool
%% succeeds end-to-end through session -> run -> tool-call with the usual
%% event trail, proving the registered descriptor drives the existing cli
%% adapter unchanged. The tool file points at a real helper script (the
%% `write_cli_helper' pattern from `soma_cli_adapter_SUITE': uppercase the
%% final argv argument), `soma_tool_config:load_dir/1' registers it, and the
%% run enters at `soma_agent_session:start_run/2' -- the same entry the v0.2
%% cli proofs use, so no execution layer is bypassed. The step output being
%% the helper's transform proves the external program really ran through the
%% cli adapter driven by the loader's descriptor.
test_config_tool_runs_end_to_end(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    Helper = write_upper_helper(Config),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_e2e"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    ToolSource = io_lib:format(
                   "(tool\n"
                   "  (name \"cfg_e2e_upper\")\n"
                   "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                   "  (executable \"~s\")\n"
                   "  (argv))\n", [Helper]),
    ok = file:write_file(filename:join(ToolsDir, "cfg_e2e_upper.lisp"),
                         unicode:characters_to_binary(ToolSource)),
    #{registered := [cfg_e2e_upper], skipped := []} =
        soma_tool_config:load_dir(ToolsDir),
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cfg_e2e_upper,
               args => #{input => <<"hello">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    %% The usual event trail of a successful one-step run, in order.
    [<<"run.accepted">>, <<"run.started">>, <<"step.started">>,
     <<"tool.started">>, <<"tool.succeeded">>, <<"step.succeeded">>,
     <<"run.completed">>] = [maps:get(event_type, E) || E <- Events],
    %% The step output carries the helper's transform of the step input,
    %% proving the external program ran through the cli adapter (the input
    %% travels to the program inside the rendered args, and only the real
    %% helper uppercases it).
    [StepEvent] = [E || E <- Events,
                        maps:get(event_type, E) =:= <<"step.succeeded">>],
    Output = maps:get(output, maps:get(payload, StepEvent)),
    {_, _} = binary:match(Output, <<"HELLO">>),
    ok.

%% Criterion 1 (#208): a tool file whose declared name matches a built-in
%% (`echo', `sleep', `fail', `file_read', `file_write') is skipped with
%% reason `{reserved_name, Name}' before `register_tool/1' is ever called —
%% a config file must not be able to replace a built-in descriptor (the
%% resume fail-safe reads `effect' / `idempotent' off exactly that
%% descriptor). The built-in resolves to the same descriptor it held before
%% the load, and a valid neighbour file in the same directory still
%% registers.
test_reserved_name_skipped_builtin_and_neighbour_intact(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    %% Snapshot the built-in descriptor before the load.
    {ok, Before} = soma_tool_registry:resolve_descriptor(file_write),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_reserved"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    %% The shadow attempt: a config file declaring the built-in's name with
    %% softened safety fields.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_shadow_file_write.lisp"),
           <<"(tool\n"
             "  (name \"file_write\")\n"
             "  (effect reader) (idempotent true)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    %% A valid neighbour in the same directory.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_neighbour.lisp"),
           <<"(tool\n"
             "  (name \"cfg_neighbour\")\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    #{registered := [cfg_neighbour], skipped := [SkipEntry]} =
        soma_tool_config:load_dir(ToolsDir),
    %% The shadow file skipped with the named reserved-name reason.
    #{file := "cfg_shadow_file_write.lisp",
      reason := {reserved_name, file_write}} = SkipEntry,
    %% The built-in resolves to the exact descriptor it held before.
    {ok, Before} = soma_tool_registry:resolve_descriptor(file_write),
    %% The neighbour still registered.
    {ok, #{adapter := cli}} =
        soma_tool_registry:resolve_descriptor(cfg_neighbour),
    ok.

%% Criterion 2 (#208): the resume-safety fields survive a shadow attempt.
%% After a load where a config file declares `(name "file_write")
%% (effect reader) (idempotent true)', `resolve_descriptor(file_write)' still
%% returns `effect => state' and `idempotent => false' -- the exact fields
%% `soma_run_resume_plan:plan/2' classifies from when deciding whether an
%% in-flight step is safe to re-run. The plan itself is not run here (its
%% classification is proven in the v0.7.3 suite); this pins its input
%% contract.
test_shadowed_file_write_keeps_resume_safety_fields(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_resume_safety"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    %% The one file in the dir: a shadow attempt softening the safety fields.
    ok = file:write_file(
           filename:join(ToolsDir, "cfg_soften_file_write.lisp"),
           <<"(tool\n"
             "  (name \"file_write\")\n"
             "  (effect reader) (idempotent true)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    #{registered := [], skipped := [_]} =
        soma_tool_config:load_dir(ToolsDir),
    %% The same lookup the resume planner classifies from still carries the
    %% built-in's conservative safety fields.
    {ok, Descriptor} = soma_tool_registry:resolve_descriptor(file_write),
    #{effect := state, idempotent := false} = Descriptor,
    ok.

%% Criterion 3 (#208): two config files in one directory declaring the same
%% name — the first in sorted filename order registers, the later file is
%% skipped with reason `{duplicate_name, Name}'. Today the fold silently
%% last-write-wins (the registry overwrites by name), so the user never
%% learns one of their files was shadowed. The duplicate check is per-load
%% (the fold's registered-so-far accumulator), not against the live registry,
%% so re-loading a directory keeps working. The resolved descriptor carrying
%% the first file's executable proves which file won.
test_duplicate_name_first_sorted_file_wins(Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join(?config(priv_dir, Config), "tools_dup"),
    ok = filelib:ensure_dir(filename:join(ToolsDir, "x")),
    %% First in sorted filename order: must win.
    ok = file:write_file(
           filename:join(ToolsDir, "a_first.lisp"),
           <<"(tool\n"
             "  (name \"cfg_dup\")\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv))\n">>),
    %% Same declared name, different executable, later filename: must skip.
    ok = file:write_file(
           filename:join(ToolsDir, "b_second.lisp"),
           <<"(tool\n"
             "  (name \"cfg_dup\")\n"
             "  (executable \"/bin/cat\")\n"
             "  (argv))\n">>),
    #{registered := [cfg_dup], skipped := [SkipEntry]} =
        soma_tool_config:load_dir(ToolsDir),
    %% The later file skipped with the named duplicate reason.
    #{file := "b_second.lisp",
      reason := {duplicate_name, cfg_dup}} = SkipEntry,
    %% The resolved descriptor carries the first file's executable — the
    %% second file never reached the registry.
    {ok, #{executable := Executable}} =
        soma_tool_registry:resolve_descriptor(cfg_dup),
    <<"/bin/echo">> = unicode:characters_to_binary(Executable),
    ok.

%% Criterion 8 (#232): the three copyable docmod examples enter through the
%% same directory loader users run at daemon boot. Successful registration
%% proves each source form compiles and passes the shared manifest normalizer;
%% the resolved descriptors then prove the examples declare their real command
%% shapes and do not soften the read/edit safety boundary.
test_docmod_example_manifests_normalize_with_expected_metadata(_Config) ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    ToolsDir = filename:join([project_root(), "examples", "docmod-tools"]),
    #{registered := [docmod_edit, docmod_help, docmod_read], skipped := []} =
        soma_tool_config:load_dir(ToolsDir),
    {ok, Help} = soma_tool_registry:resolve_descriptor(docmod_help),
    #{adapter := cli, effect := reader, idempotent := true,
      argv := [<<"help">>, <<"{topic}">>]} = Help,
    {ok, Read} = soma_tool_registry:resolve_descriptor(docmod_read),
    #{adapter := cli, effect := reader, idempotent := true,
      argv := [<<"read">>, <<"{input}">>]} = Read,
    {ok, Edit} = soma_tool_registry:resolve_descriptor(docmod_edit),
    #{adapter := cli, effect := state, idempotent := false,
      argv := [<<"edit">>, <<"{input}">>, <<"{changes}">>]} = Edit,
    ok.

%% Test beams run from `_build', so source-tree examples need an explicit
%% project root rather than Common Test's per-run working directory.
project_root() ->
    walk_up_to_apps(filename:dirname(code:which(?MODULE))).

walk_up_to_apps(Dir) ->
    case filelib:is_dir(filename:join(Dir, "apps")) of
        true -> Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> erlang:error(project_root_not_found);
                _ -> walk_up_to_apps(Parent)
            end
    end.

%% Write a tiny cli helper into the case's priv_dir: uppercase the last argv
%% argument and print it to stdout, exit 0 (the `write_cli_helper' pattern
%% from `soma_cli_adapter_SUITE' -- input travels as the final argv argument,
%% never stdin).
write_upper_helper(Config) ->
    Path = filename:join(?config(priv_dir, Config), "cfg_upper_helper.sh"),
    Script = <<"#!/bin/sh\n"
               "for a in \"$@\"; do last=\"$a\"; done\n"
               "printf '%s' \"$last\" | tr '[:lower:]' '[:upper:]'\n">>,
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

%% The running runtime's event store pid, read from soma_sup.
event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

%% Poll the run's event trail until `run.completed' appears.
wait_for_run_completed(_StorePid, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(StorePid, RunId, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(<<"run.completed">>, Types) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_run_completed(StorePid, RunId, N - 1)
    end.

%% The sorted tool names of the running registry, via the pure `names/1' on
%% the gen_server's registry-map state.
registered_names() ->
    lists:sort(soma_tool_registry:names(sys:get_state(soma_tool_registry))).

%% The captured skip reason for one file's boot diagnostic, or a failed case.
receive_skip(File) ->
    receive
        {tool_skip, File, Reason} -> Reason
    after 2000 ->
        ct:fail({no_skip_diagnostic_for, File})
    end.

%% Logger handler callback: forward the loader's per-file skip warning to the
%% test process as `{tool_skip, Basename, Reason}'; ignore everything else.
%% Handler callbacks run in the logging client's process, so the forwards
%% arrive before `soma_cli:daemon/1' returns.
log(#{msg := {"soma tool config: skipped ~s: ~p", [File, Reason]}},
    #{config := #{pid := Pid}}) ->
    Pid ! {tool_skip, File, Reason},
    ok;
log(_LogEvent, _HandlerConfig) ->
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
