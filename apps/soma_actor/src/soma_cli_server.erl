%% @doc CLI daemon socket server. A Unix-domain (`{local, Path}') listener with
%% shared bounded framing; one handler process per accepted connection. The wire
%% is Lisp s-exprs, and Lisp only. A `(run (step ...) ...)' request is parsed by
%% `soma_lfe:compile/2', run under a `soma_run' the handler owns, and the terminal
%% result is rendered back as a `(result ...)' s-expr by `soma_lisp:render/1'. An
%% `(ask (intent "..."))' request drives the agent decision loop instead: the
%% handler starts a `soma_actor' under `soma_actor_sup' with the daemon's
%% `model_config', calls `soma_actor:ask/3', and renders the terminal answer as the
%% same `(result ...)' form.
-module(soma_cli_server).

-export([start_link/1, frame/1, unframe/1]).
-export([ask_envelope/4]).

%% Start the listener. `start_link(#{socket => Path})' opens an AF_UNIX
%% (`{local, Path}') raw socket through the shared path owner and runs an accept
%% loop in a linked process, spawning one handler per accepted connection.
%% An optional `model_config' is the agent decision config the ask path drives the
%% mock (or, by config, a real provider) with; absent it, the ask path has no mock
%% to drive and the run path is unchanged.
-spec start_link(#{socket := file:filename_all(),
                   model_config => term(),
                   tools_dir => file:filename_all()}) ->
    {ok, pid()} | {error, term()}.
start_link(#{socket := Path} = Opts) ->
    ModelConfig = maps:get(model_config, Opts, undefined),
    ToolsDir = maps:get(tools_dir, Opts, undefined),
    Parent = self(),
    Pid = spawn_link(fun() -> listen(Parent, Path, ModelConfig, ToolsDir) end),
    receive
        {Pid, listening} -> {ok, Pid};
        {Pid, {error, Reason}} -> {error, Reason}
    end.

listen(Parent, Path, ModelConfig, ToolsDir) ->
    process_flag(trap_exit, true),
    case soma_socket_path:listen(Path) of
        {ok, ListenSocket, OwnershipToken} ->
            try
                ok = ensure_task_registry(),
                Parent ! {self(), listening},
                accept_loop(ListenSocket, ModelConfig, ToolsDir, self())
            after
                _ = soma_socket_path:close(ListenSocket, OwnershipToken)
            end;
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

accept_loop(ListenSocket, ModelConfig, ToolsDir, Listener) ->
    %% Drain any pending teardown signal before each accept. A `(stop)' handler
    %% (which does not own the listen socket) sends `close_listen' to this
    %% listener -- the process that owns the listen socket -- and the listener
    %% closes it here, which ends this loop via the `{error, closed}' clause so
    %% the daemon stops accepting. Checking before each accept (rather than only
    %% on an accept timeout) means a steady stream of new connections cannot
    %% starve the signal.
    receive
        close_listen ->
            ok;
        {'EXIT', _From, normal} ->
            accept_loop(ListenSocket, ModelConfig, ToolsDir, Listener);
        {'EXIT', _From, _Reason} ->
            ok
    after 0 ->
        %% A short accept timeout bounds the wait so the signal is observed even
        %% when no connection arrives.
        case gen_tcp:accept(ListenSocket, 200) of
            {ok, Socket} ->
                %% The accepted socket is owned by this accept-loop process. Hand
                %% it to the handler so socket events under `{active, once}' (the
                %% client-disconnect `{tcp_closed, Socket}') are delivered to the
                %% handler's mailbox -- the process that waits in `await_run' --
                %% and not stranded here in the acceptor. The handler waits for
                %% `proceed' so it only touches the socket once it owns it. The
                %% handler carries the daemon's `model_config' so an ask request
                %% can drive the actor, and the listener pid so a `(stop)'
                %% request can signal teardown.
                Handler = spawn(
                            fun() ->
                                    wait_then_handle(Socket, ModelConfig,
                                                     ToolsDir, Listener)
                            end),
                ok = gen_tcp:controlling_process(Socket, Handler),
                Handler ! proceed,
                accept_loop(ListenSocket, ModelConfig, ToolsDir, Listener);
            {error, timeout} ->
                accept_loop(ListenSocket, ModelConfig, ToolsDir, Listener);
            {error, closed} ->
                ok
        end
    end.

wait_then_handle(Socket, ModelConfig, ToolsDir, Listener) ->
    receive
        proceed -> handle(Socket, ModelConfig, ToolsDir, Listener)
    end.

%% Per-connection handler, one process per accepted connection. It reads one
%% framed `(run ...)' request, drives a supervised run it owns directly, frames
%% the terminal `(result ...)' s-expr back, then closes. The shared codec reads
%% and writes the length prefix while this handler sees the bare s-expression.
handle(Socket, ModelConfig, ToolsDir, Listener) ->
    case soma_socket_frame:recv(Socket, 60000) of
        {ok, Bytes} ->
            case handle_lisp_request(Bytes, Socket, ModelConfig, ToolsDir,
                                     Listener) of
                noreply ->
                    gen_tcp:close(Socket);
                Reply ->
                    _ = soma_socket_frame:send(Socket, Reply),
                    gen_tcp:close(Socket)
            end;
        {error, _} ->
            ok
    end.

%% Parse the Lisp `(run ...)' request with `soma_lfe', run it, and render the
%% terminal result map as a `(result ...)' s-expr. A malformed request --
%% `soma_lfe:compile/2' returning `{error, Diagnostics}', or the reader crashing
%% on garbage bytes -- is not a handler crash: it renders a `(result ...)' with
%% `status => error' and an `error' sub-form carrying the diagnostics.
handle_lisp_request(Bytes, Socket, ModelConfig, ToolsDir, Listener) ->
    %% Tool-management verbs are their own wire forms, not `soma_lfe' forms, so
    %% dispatch them before the `soma_lfe:compile/2' path. A `(tool-register
    %% (tool ...))' request compiles the inner `(tool ...)' body through the same
    %% compiler the boot loader uses and registers it in the live registry; a
    %% `(tool-list)' request renders the live registry's list projection.
    case tool_management_form(Bytes) of
        {register, ToolForm} ->
            handle_tool_register(ToolForm, ToolsDir);
        list ->
            handle_tool_list();
        {remove, NameBin} ->
            handle_tool_remove(NameBin, ToolsDir);
        not_tool_management ->
            handle_lfe_request(Bytes, Socket, ModelConfig, Listener)
    end.

%% Peek at the request: classify a tool-management wire form -- the inner
%% `(tool ...)' body of a `(tool-register (tool ...))' request, a bare
%% `(tool-list)', or the name string of a `(tool-remove "<name>")'. Anything
%% else (including garbage the reader cannot parse) is `not_tool_management'
%% and falls through to the existing `soma_lfe' path, which renders the
%% malformed-request error.
tool_management_form(Bytes) ->
    try soma_lfe_reader:read_forms(Bytes) of
        {ok, [['tool-register', ToolForm]]} -> {register, ToolForm};
        {ok, [['tool-list']]} -> list;
        {ok, [['tool-remove', NameBin]]} when is_binary(NameBin) ->
            {remove, NameBin};
        _ -> not_tool_management
    catch
        _:_ -> not_tool_management
    end.

%% Compile the `(tool ...)' body through the shared boot-loader compiler,
%% register the resulting manifest in the running registry (which normalizes
%% it), and render the terminal reply. A valid register makes the named tool
%% resolve live on this daemon before any restart. Admission gates run before
%% any side effect: a built-in name is `{reserved_name, Name}', and a name that
%% already resolves live (a config tool -- built-ins were caught above) is
%% `{already_registered, Name}' -- distinct from the boot loader's per-load
%% `{duplicate_name, Name}' because it checks live registry state. A compile or
%% registration error renders an `error' result carrying the reason verbatim.
handle_tool_register(ToolForm, ToolsDir) ->
    case soma_tool_config:compile_form(ToolForm) of
        {ok, #{name := Name} = Manifest} ->
            case lists:member(Name, soma_tool_registry:builtin_names()) of
                true ->
                    soma_lisp:render(#{status => error,
                                       error => {reserved_name, Name}});
                false ->
                    case soma_tool_registry:resolve_descriptor(Name) of
                        {ok, _Existing} ->
                            soma_lisp:render(#{status => error,
                                               error => {already_registered,
                                                         Name}});
                        {error, not_found} ->
                            case soma_tool_manifest:normalize(Manifest) of
                                {ok, _Descriptor} ->
                                    register_normalized_tool(Name, Manifest,
                                                             ToolsDir);
                                {error, Reason} ->
                                    %% Validate BEFORE touching disk: a
                                    %% manifest normalize rejects (missing
                                    %% executable/argv, bad effect, ...) is a
                                    %% clean error reply -- it must never
                                    %% reach the file renderer (which pattern-
                                    %% requires the cli fields) or leave a
                                    %% transient file in the tools dir.
                                    soma_lisp:render(#{status => error,
                                                       error => Reason})
                            end
                    end
            end;
        {error, Reason} ->
            soma_lisp:render(#{status => error, error => Reason})
    end.

%% Persist the validated manifest, then register it in the running registry,
%% once the reserved-name gate and `normalize/1' have both passed. The file is
%% written FIRST: a disk failure then leaves the registry untouched, so a
%% caller told `error' never has a live-only registration that a restart would
%% silently drop. A write failure (including a missing tools dir the daemon
%% cannot create) is a named `error' reply, never a handler crash. If the
%% registry rejects the manifest after a successful write, the file just
%% written is deleted so a restart cannot load a manifest the caller was told
%% failed.
register_normalized_tool(Name, Manifest, ToolsDir) ->
    case write_manifest_file(ToolsDir, Name, Manifest) of
        ok ->
            case soma_tool_registry:register_tool(Manifest) of
                ok ->
                    ok = append_tool_registered_event(Name, Manifest),
                    ["(result (status registered) (tool-name ",
                     soma_lisp:render(atom_to_binary(Name, utf8)), "))"];
                {error, Reason} ->
                    _ = delete_manifest_file(ToolsDir, Name),
                    soma_lisp:render(#{status => error, error => Reason})
            end;
        {error, Reason} ->
            soma_lisp:render(#{status => error,
                               error => {manifest_write_failed, Reason}})
    end.

%% Append the one bounded `tool.registered' event for a successful register.
%% `soma_event_store:append/2' fills the run/session/step ids with `undefined'
%% (tool management belongs to no run); the payload is built from named safe
%% fields alone -- the tool name plus `effect' / `idempotent' / `adapter' --
%% never the executable path, argv values, pids, ports, or refs.
append_tool_registered_event(Name, #{effect := Effect,
                                     idempotent := Idempotent,
                                     adapter := Adapter}) ->
    soma_event_store:append(
      event_store_pid(),
      #{event_type => <<"tool.registered">>,
        payload => #{tool_name => Name, effect => Effect,
                     idempotent => Idempotent, adapter => Adapter}}).

%% Persist the normalized manifest to `<ToolsDir>/<name>.lisp' so a restart
%% re-registers the same descriptor from the boot-time `load_dir/1'. The path is
%% always the configured tools dir plus the tool name as a basename -- never a
%% caller-supplied path.
write_manifest_file(ToolsDir, Name, Manifest) ->
    Path = filename:join(ToolsDir, atom_to_list(Name) ++ ".lisp"),
    case filelib:ensure_dir(Path) of
        ok -> file:write_file(Path, render_tool_manifest(Manifest));
        {error, _} = Error -> Error
    end.

%% Render a normalized cli manifest back to a `(tool ...)' s-expr that
%% `soma_tool_config:compile_form/1' re-reads to the same manifest -- the
%% round-trip the boot loader depends on. Config tools are always `cli'
%% (`compile_form/1' gates the adapter), so only the cli shape is rendered.
%% `params' is included whenever the manifest carries it: a templated argv's
%% placeholders only resolve after a reload if their param declarations
%% survive the round-trip (dropping them here made `load_dir/1' skip the file
%% on the very next boot with `{unknown_argv_placeholder, _}').
render_tool_manifest(#{name := Name, effect := Effect,
                       idempotent := Idempotent, timeout_ms := TimeoutMs,
                       adapter := cli, executable := Executable,
                       argv := Argv} = Manifest) ->
    Fields =
        [render_string_field(name, atom_to_binary(Name, utf8))]
        ++ render_optional_description(Manifest)
        ++ [render_atom_field(effect, Effect),
            render_atom_field(idempotent, Idempotent),
            ["(timeout-ms ", integer_to_list(TimeoutMs), ")"],
            render_atom_field(adapter, cli),
            render_string_field(executable, Executable),
            render_argv_field(Argv)]
        ++ render_optional_params(Manifest),
    ["(tool ", lists:join(" ", Fields), ")\n"].

render_optional_description(#{description := Description}) ->
    [render_string_field(description, Description)];
render_optional_description(_Manifest) ->
    [].

render_optional_params(#{params := Params}) when is_list(Params), Params =/= [] ->
    Rows = [render_param_row(Param) || Param <- Params],
    [["(params (", lists:join(" ", Rows), "))"]];
render_optional_params(_Manifest) ->
    [].

render_param_row(#{name := Name, type := Type, required := Required} = Param) ->
    RequiredSymbol = case Required of
                         true -> "required";
                         false -> "optional"
                     end,
    Parts = [soma_lisp:render(Name), atom_to_list(Type), RequiredSymbol]
        ++ render_optional_param_doc(Param),
    ["(", lists:join(" ", Parts), ")"].

render_optional_param_doc(#{doc := Doc}) ->
    [soma_lisp:render(Doc)];
render_optional_param_doc(_Param) ->
    [].

render_string_field(Key, Value) ->
    ["(", atom_to_list(Key), " ", soma_lisp:render(Value), ")"].

render_atom_field(Key, Value) ->
    ["(", atom_to_list(Key), " ", atom_to_list(Value), ")"].

render_argv_field(Argv) ->
    ["(argv", [[" ", soma_lisp:render(Arg)] || Arg <- Argv], ")"].

%% Render the live registry's list projection as the `(tool-list ...)' reply:
%% one `(tool ...)' entry per live tool, each carrying `name' / `effect' /
%% `idempotent' / `adapter' plus `description' only when the descriptor has
%% one. The projection (`soma_tool_registry:list_tools/0') is built from named
%% safe fields, so runtime internals never reach the wire.
handle_tool_list() ->
    Entries = soma_tool_registry:list_tools(),
    ["(tool-list",
     [[" ", render_tool_summary(Entry)] || Entry <- Entries],
     ")"].

render_tool_summary(#{name := Name, effect := Effect,
                      idempotent := Idempotent, adapter := Adapter} = Entry) ->
    Fields =
        [render_string_field(name, atom_to_binary(Name, utf8)),
         render_atom_field(effect, Effect),
         render_atom_field(idempotent, Idempotent),
         render_atom_field(adapter, Adapter)]
        ++ [render_string_field(description, Description)
            || {ok, Description} <- [maps:find(description, Entry)]],
    ["(tool ", lists:join(" ", Fields), ")"].

%% Remove a config tool from the running registry so its name no longer
%% resolves on this daemon, and delete its persisted manifest file. The wire
%% carries the name as a binary; it is mapped to an *existing* registry atom
%% (never minted), and only a live non-built-in tool -- the definition of a
%% config tool -- is removable. Any other name (built-in, unknown, or
%% traversal-shaped) is rejected with `{not_config_tool, Name}' before
%% anything is touched. The deleted path is always the configured tools dir
%% plus the tool name as a basename -- never a caller-supplied path -- so a
%% remove can only ever delete inside the tools directory.
handle_tool_remove(NameBin, ToolsDir) ->
    case config_tool_name(NameBin) of
        {ok, Name} ->
            %% Delete the persisted file FIRST and check the result: a file
            %% that survives (eacces, a read-only dir) would re-register the
            %% tool at the next boot, so replying `removed' while it remains
            %% would be a silent resurrection. Only a missing file (`enoent')
            %% is tolerated; any other delete error is a named reply and the
            %% live registration is left untouched, so live and durable state
            %% never contradict.
            case delete_manifest_file(ToolsDir, Name) of
                Deleted when Deleted =:= ok;
                             Deleted =:= {error, enoent} ->
                    ok = soma_tool_registry:unregister_tool(Name),
                    ok = append_tool_removed_event(Name),
                    ["(result (status removed) (tool-name ",
                     soma_lisp:render(NameBin), "))"];
                {error, Reason} ->
                    soma_lisp:render(#{status => error,
                                       error => {manifest_delete_failed,
                                                 Reason}})
            end;
        error ->
            soma_lisp:render(#{status => error,
                               error => {not_config_tool,
                                         known_tool_name(NameBin)}})
    end.

%% Map a rejected wire name back to an *existing* tool atom when one exists --
%% a built-in or a live registry name -- so the error reason carries the name
%% the way the register gates do (`{reserved_name, echo}', atom). No atom is
%% ever minted from external input: an unknown name stays a binary.
known_tool_name(NameBin) ->
    Known = soma_tool_registry:builtin_names()
        ++ [maps:get(name, Entry) || Entry <- soma_tool_registry:list_tools()],
    case [Name || Name <- Known, atom_to_binary(Name, utf8) =:= NameBin] of
        [Name | _] -> Name;
        [] -> NameBin
    end.

%% Append the one bounded `tool.removed' event for a successful remove -- the
%% mirror of `append_tool_registered_event/2'. `soma_event_store:append/2'
%% fills the run/session/step ids with `undefined' (tool management belongs to
%% no run); the payload carries the removed tool's name alone -- never the
%% executable path, argv values, pids, ports, or refs.
append_tool_removed_event(Name) ->
    soma_event_store:append(
      event_store_pid(),
      #{event_type => <<"tool.removed">>,
        payload => #{tool_name => Name}}).

%% Delete the persisted manifest at `<ToolsDir>/<name>.lisp' -- the mirror of
%% `write_manifest_file/3', built from the configured dir plus the tool name as
%% a basename. A missing file is harmless (`file:delete' returns
%% `{error, enoent}'): every config tool has a backing file today, but the
%% remove must not fail if one does not.
delete_manifest_file(ToolsDir, Name) ->
    file:delete(filename:join(ToolsDir, atom_to_list(Name) ++ ".lisp")).

%% Map a wire name (binary) to the atom of a live config tool: a name that
%% resolves in the running registry and is not a built-in. Matching against the
%% live registry's own names -- rather than `binary_to_atom/2' -- means no new
%% atom is ever minted from external input, and a bogus name simply fails to
%% match.
config_tool_name(NameBin) ->
    Builtins = soma_tool_registry:builtin_names(),
    Live = [maps:get(name, Entry) || Entry <- soma_tool_registry:list_tools()],
    case [Name || Name <- Live,
                  not lists:member(Name, Builtins),
                  atom_to_binary(Name, utf8) =:= NameBin] of
        [Name] -> {ok, Name};
        [] -> error
    end.

handle_lfe_request(Bytes, Socket, ModelConfig, Listener) ->
    Compiled = try soma_lfe:compile(Bytes, #{})
               catch
                   Class:Reason ->
                       {error, [#{code => malformed_request,
                                  message => iolist_to_binary(
                                               io_lib:format("~p:~p",
                                                             [Class, Reason]))}]}
               end,
    case Compiled of
        {ok, #{run := #{steps := Steps, detach := true}}} ->
            run_steps_detached(Steps);
        {ok, #{run := #{steps := Steps}}} ->
            run_steps(Steps, Socket);
        {ok, #{ask := Ask}} ->
            handle_ask(Ask, ModelConfig, Socket);
        {ok, #{trace := #{correlation_id := CorrId}}} ->
            handle_trace(CorrId);
        {ok, #{status := #{task_id := TaskId}}} ->
            handle_status(TaskId);
        {ok, #{cancel := #{task_id := TaskId}}} ->
            handle_cancel(TaskId);
        {ok, #{stop := _Stop}} ->
            handle_stop(Listener);
        {error, Diagnostics} ->
            soma_lisp:render(#{status => error, error => Diagnostics})
    end.

%% Drive the agent decision loop for an `(ask (intent "..."))' request. The
%% compiled ask map carries the required `intent' (plus optional `tool_policy' /
%% `budget'). The handler starts a `soma_actor' under `soma_actor_sup' with the
%% daemon's `model_config' and the ask's tool policy / budget, then calls
%% `soma_actor:ask/3' with an `llm' envelope so the decision loop runs the mock
%% (the directive opts come from `model_config', threaded as the envelope's
%% `llm' map). A `reply' proposal completes the task with `{ok, #{kind => reply,
%% text => Text}}', which renders as a completed `(result ...)' whose outputs
%% carry the reply text.
handle_ask(Ask, ModelConfig, Socket) ->
    TaskId = mint_id("task"),
    CorrId = mint_id("corr"),
    case has_model(ModelConfig) of
        false ->
            %% No model is configured (no `~/.soma/config': `model_config' is
            %% `undefined', `#{}', or a map carrying neither a `directive' nor a
            %% `provider' key). Short-circuit to a named `failed' result without
            %% starting the actor or the call -- so an empty `llm' map never reaches
            %% `soma_llm_call:perform_call/1', where it would throw `function_clause'
            %% and leak the raw stack term onto the wire. Nothing is spawned, so the
            %% listener and the next request are untouched.
            soma_lisp:render(#{status => failed,
                               task_id => TaskId,
                               correlation_id => CorrId,
                               error => no_model_configured});
        true ->
            handle_ask_with_model(Ask, ModelConfig, TaskId, CorrId, Socket)
    end.

%% A `model_config' is usable when it is a map carrying a mock `directive' or a
%% real `provider' key. `undefined', `#{}', and any other shape are no-model.
has_model(ModelConfig) when is_map(ModelConfig) ->
    maps:is_key(directive, ModelConfig) orelse maps:is_key(provider, ModelConfig);
has_model(_ModelConfig) ->
    false.

handle_ask_with_model(Ask, ModelConfig, TaskId, CorrId, Socket) ->
    Intent = maps:get(intent, Ask),
    Opts0 = #{actor_id => mint_id("actor"),
              model_config => ModelConfig,
              event_store => event_store_pid()},
    Opts1 = case maps:find(tool_policy, Ask) of
                {ok, Policy} -> Opts0#{tool_policy => Policy};
                error -> Opts0
            end,
    ConfigBudget = configured_explore_budget(ModelConfig),
    Budget = maps:merge(ConfigBudget, maps:get(budget, Ask, #{})),
    Opts2 = case map_size(Budget) of
                0 -> Opts1;
                _ -> Opts1#{budget => Budget}
            end,
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts2),
    Llm = mock_llm_opts(ModelConfig),
    Envelope = ask_envelope(Intent, TaskId, CorrId, Llm),
    Handler = self(),
    AskTag = make_ref(),
    {AskPid, AskMRef} =
        spawn_monitor(
          fun() ->
                  Handler ! {ask_result, AskTag,
                             soma_actor:ask(ActorPid, Envelope, 60000)}
          end),
    ok = inet:setopts(Socket, [{active, once}]),
    case await_ask(AskTag, AskPid, AskMRef, Socket) of
        noreply ->
            noreply;
        AskResult ->
            Result = ask_result(AskResult, TaskId, CorrId),
            soma_lisp:render(Result)
    end.

ask_result(AskResult, TaskId, CorrId) ->
    case AskResult of
                 {ok, #{kind := reply, text := Text}} ->
                     #{status => completed,
                       task_id => TaskId,
                       correlation_id => CorrId,
                       outputs => #{reply => Text}};
                 {ok, #{kind := reject, reason := Reason}} ->
                     %% The LLM declined: a `reject' proposal is approved by
                     %% policy (it runs nothing) and comes back as the task
                     %% result, but it is not a completed answer. Render it as a
                     %% `rejected' result whose `error' sub-form carries the
                     %% reject reason.
                     #{status => rejected,
                       task_id => TaskId,
                       correlation_id => CorrId,
                       error => Reason};
                 {error, {rejected, Reason}} ->
                     %% The policy gate rejected the proposal (e.g. a `run_steps'
                     %% naming a tool outside the allowlist). Same terminal shape
                     %% as a `reject' proposal: a `rejected' result carrying the
                     %% reason.
                     #{status => rejected,
                       task_id => TaskId,
                       correlation_id => CorrId,
                       error => Reason};
                 {ok, Other} ->
                     #{status => completed,
                       task_id => TaskId,
                       correlation_id => CorrId,
                       outputs => Other};
                 {error, Reason} ->
                     #{status => failed,
                       task_id => TaskId,
                       correlation_id => CorrId,
                       error => Reason};
                 timeout ->
                     #{status => timeout,
                       task_id => TaskId,
                       correlation_id => CorrId}
    end.

await_ask(AskTag, AskPid, AskMRef, Socket) ->
    receive
        {ask_result, AskTag, AskResult} ->
            erlang:demonitor(AskMRef, [flush]),
            AskResult;
        {'DOWN', AskMRef, process, AskPid, _Reason} ->
            noreply;
        {tcp, Socket, _Ignored} ->
            ok = inet:setopts(Socket, [{active, once}]),
            await_ask(AskTag, AskPid, AskMRef, Socket);
        {tcp_closed, Socket} ->
            exit(AskPid, kill),
            erlang:demonitor(AskMRef, [flush]),
            noreply
    end.

%% Exploration limits are daemon configuration, while the actor remains their
%% enforcement owner. Only an enabled explore model contributes these fields;
%% absent settings preserve the existing actor-option shape.
configured_explore_budget(#{explore := true} = ModelConfig) ->
    maps:with([max_explore_rounds, max_observation_bytes], ModelConfig);
configured_explore_budget(_ModelConfig) ->
    #{}.

%% Handle a `(stop)' request: signal the listener to close the listen socket,
%% then return the terminal `(result (status stopped))' reply. The handler does
%% not own the listen socket -- the listener (the accept-loop process) does -- so
%% it sends a `close_listen' signal the listener acts on between accepts. Closing
%% the listen socket ends the accept loop, so the daemon stops accepting new
%% connections; it does not disturb this already-accepted connection, so the
%% reply still flushes to the stopping client. The listener also unlinks the
%% socket file after closing the listen socket. Before signalling teardown the
%% handler asks the daemon-owned registry to cancel every running detached run --
%% stop cancels in-flight runs rather than refusing while busy -- so each
%% `soma_run' tears down its worker and emits `run.cancelled' on the way out.
handle_stop(Listener) ->
    _ = cancel_inflight_runs(),
    Listener ! close_listen,
    ["(result (status stopped))"].

%% Cancel every running detached run the registry owns. Absent a registry (no
%% detached run was ever started) there is nothing in flight to cancel.
cancel_inflight_runs() ->
    case whereis(soma_cli_task_registry) of
        undefined -> ok;
        _Pid -> soma_cli_task_registry:cancel_all()
    end.

%% Render a `(trace "<corr>")' read request. `soma_trace:render_lisp/2' fetches
%% the correlation chain from the event store, sorts it by timestamp ascending,
%% and renders one event s-expr per event in that order; this wraps those ordered
%% event sub-forms in a single `(trace ...)' head. For a completed run the last
%% sub-form by timestamp is the `run.completed' event.
handle_trace(CorrId) ->
    Events = soma_trace:render_lisp(event_store_pid(), CorrId),
    ["(trace ", Events, ")"].

%% Render a `(status "<task>")' read request. Live detached tasks are daemon-owned
%% and live in `soma_cli_task_registry', so read that first; older synchronous
%% tasks still derive terminal state from the event store. The run path sets the
%% run's `session_id' to the task id, so a task's events are reachable by
%% `by_session/2' even though the store has no `by_task' query.
handle_status(TaskId) ->
    State = case soma_cli_task_registry:lookup(TaskId) of
                {ok, #{status := RegistryState}} ->
                    RegistryState;
                {error, not_found} ->
                    Events = soma_event_store:by_session(event_store_pid(),
                                                         TaskId),
                    derive_state(Events)
            end,
    ["(status (state ", atom_to_list(State), "))"].

%% Fire a cancellation request for a live detached task. The registry only sends
%% the existing `cancel' message to the run; `soma_run' owns worker teardown and
%% `run.cancelled' emission. The handler then waits briefly for the registry to
%% observe the run's terminal message and reports that state to the client.
handle_cancel(TaskId) ->
    case soma_cli_task_registry:cancel(TaskId) of
        ok ->
            Task = wait_for_cancel_terminal(TaskId, 100),
            render_cancel_result(TaskId, Task);
        {error, {not_running, Status}} ->
            render_terminal_cancel_result(Status);
        {error, not_found} ->
            case derive_state(soma_event_store:by_session(event_store_pid(),
                                                          TaskId)) of
                unknown ->
                    render_cancel_result(TaskId, #{status => unknown,
                                                   error => not_found});
                Status ->
                    render_terminal_cancel_result(Status)
            end
    end.

wait_for_cancel_terminal(TaskId, 0) ->
    lookup_cancel_task(TaskId);
wait_for_cancel_terminal(TaskId, N) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, #{status := running}} ->
            timer:sleep(20),
            wait_for_cancel_terminal(TaskId, N - 1);
        {ok, Task} ->
            Task;
        {error, not_found} ->
            #{status => unknown, error => not_found}
    end.

lookup_cancel_task(TaskId) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, Task} -> Task;
        {error, not_found} -> #{status => unknown, error => not_found}
    end.

render_cancel_result(TaskId, Task) ->
    Status = maps:get(status, Task, unknown),
    ["(result (status ", atom_to_list(Status), ") "
     "(task-id ", soma_lisp:render(TaskId), ")",
     render_cancel_error(Task),
     render_cancel_correlation(Task),
     ")"].

render_terminal_cancel_result(Status) ->
    ["(result (status ", atom_to_list(Status), ") "
     "(note already-terminal))"].

render_cancel_error(#{error := Reason}) ->
    [" (error ", soma_lisp:render(Reason), ")"];
render_cancel_error(_Task) ->
    [].

render_cancel_correlation(#{correlation_id := CorrId}) ->
    [" (correlation-id ", soma_lisp:render(CorrId), ")"];
render_cancel_correlation(_Task) ->
    [].

%% Map a task's event chain to a terminal state. A run records exactly one of the
%% terminal `run.*' events, so the first match wins; an empty chain is `unknown'.
derive_state(Events) ->
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(<<"run.completed">>, Types) of
        true -> completed;
        false ->
            case lists:member(<<"run.failed">>, Types) of
                true -> failed;
                false ->
                    case lists:member(<<"run.timeout">>, Types) of
                        true -> timeout;
                        false ->
                            case lists:member(<<"run.cancelled">>, Types) of
                                true -> cancelled;
                                false -> unknown
                            end
                    end
            end
    end.

%% Build the `ask' envelope the handler delivers to `soma_actor:ask/3'. Pure, so
%% the payload key the intent lands under is unit-pinnable against the key
%% `soma_actor:build_call_opts/2' reads it back from.
-spec ask_envelope(binary(), binary(), binary(), map()) -> map().
ask_envelope(Intent, TaskId, CorrId, Llm) ->
    #{type => <<"ask">>,
      payload => #{prompt => Intent},
      task_id => TaskId,
      correlation_id => CorrId,
      llm => Llm}.

%% The mock directive opts the actor drives `soma_llm_call' with. A mock
%% `model_config' (carrying a `directive', no `provider') is the envelope's `llm'
%% map directly; `build_call_opts/2' returns it unchanged for the mock path.
mock_llm_opts(ModelConfig) when is_map(ModelConfig) ->
    ModelConfig;
mock_llm_opts(_ModelConfig) ->
    #{}.

run_steps(Steps, Socket) ->
    TaskId = mint_id("task"),
    CorrId = mint_id("corr"),
    RunId = mint_id("run"),
    {ok, RunPid} = soma_run_sup:start_run(
        #{run_id => RunId,
          session_id => TaskId,
          session_pid => self(),
          event_store => event_store_pid(),
          steps => Steps,
          correlation_id => CorrId}),
    %% Watch the socket while waiting for the run. With `{active, once}' a client
    %% disconnect is delivered to this handler's mailbox as `{tcp_closed, Socket}'
    %% (invisible to a blocked `{active, false}' socket), so await_run can cancel
    %% the in-flight run instead of waiting out the orphaned sleep step.
    ok = inet:setopts(Socket, [{active, once}]),
    case await_run(RunId, TaskId, CorrId, RunPid, Socket) of
        noreply ->
            noreply;
        Result ->
            soma_lisp:render(Result)
    end.

run_steps_detached(Steps) ->
    ok = ensure_task_registry(),
    TaskId = mint_id("task"),
    CorrId = mint_id("corr"),
    RunId = mint_id("run"),
    {ok, _Info} = soma_cli_task_registry:start_detached_run(
                    TaskId, CorrId, RunId, Steps, event_store_pid()),
    render_accepted(TaskId, CorrId).

ensure_task_registry() ->
    case whereis(soma_cli_task_registry) of
        undefined ->
            case soma_cli_task_registry:start_link() of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok
            end;
        _Pid ->
            ok
    end.

render_accepted(TaskId, CorrId) ->
    ["(accepted (task-id \"", TaskId, "\") "
     "(correlation-id \"", CorrId, "\"))"].

%% Wait for the owned run's terminal message and shape the result map. On
%% `run_completed' the recorded step outputs become the `outputs' sub-form; on a
%% failure the status is non-`completed' and the reason travels in `error'.
await_run(RunId, TaskId, CorrId, RunPid, Socket) ->
    receive
        {run_completed, RunId, Outputs} ->
            #{status => completed,
              task_id => TaskId,
              correlation_id => CorrId,
              outputs => Outputs};
        {run_failed, RunId, Reason} ->
            #{status => failed,
              task_id => TaskId,
              correlation_id => CorrId,
              error => Reason};
        {run_timeout, RunId} ->
            #{status => timeout, task_id => TaskId, correlation_id => CorrId};
        {run_cancelled, RunId} ->
            #{status => cancelled, task_id => TaskId, correlation_id => CorrId};
        {tcp, Socket, _Ignored} ->
            ok = inet:setopts(Socket, [{active, once}]),
            await_run(RunId, TaskId, CorrId, RunPid, Socket);
        {tcp_closed, Socket} ->
            %% The client dropped mid-run. Cancel the in-flight run the same way
            %% the session does -- a bare `cancel' to the live run pid -- and
            %% return without a reply: the client that would read it is already
            %% gone.
            RunPid ! cancel,
            noreply
    end.

%% Locate the running event store pid from the booted supervision tree, the same
%% way `soma_agent_session' does, so the run the handler owns emits its event
%% trail (the test seam this slice asserts on reads `run.cancelled' from there).
event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

mint_id(Prefix) ->
    list_to_binary(
      Prefix ++ "-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

%% Compatibility wrappers retained for callers that exercise the pure wire
%% contract without opening a socket. The shared codec owns the prefix logic.
-spec frame(iodata()) -> iolist().
frame(Payload) ->
    soma_socket_frame:frame(Payload).

-spec unframe(binary()) -> binary().
unframe(Framed) ->
    soma_socket_frame:unframe(Framed).
