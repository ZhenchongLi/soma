%% @doc CLI daemon socket server. A Unix-domain (`{local, Path}') listener with
%% `{packet, 4}' framing; one handler process per accepted connection. The wire is
%% Lisp s-exprs, and Lisp only. A `(run (step ...) ...)' request is parsed by
%% `soma_lfe:compile/2', run under a `soma_run' the handler owns, and the terminal
%% result is rendered back as a `(result ...)' s-expr by `soma_lisp:render/1'. An
%% `(ask (intent "..."))' request drives the agent decision loop instead: the
%% handler starts a `soma_actor' under `soma_actor_sup' with the daemon's
%% `model_config', calls `soma_actor:ask/3', and renders the terminal answer as the
%% same `(result ...)' form.
-module(soma_cli_server).

-export([start_link/1, frame/1, unframe/1]).

%% Start the listener. `start_link(#{socket => Path})' opens an AF_UNIX
%% (`{local, Path}') listening socket with `{packet, 4}' framing and runs an
%% accept loop in a linked process, spawning one handler per accepted connection.
%% An optional `model_config' is the agent decision config the ask path drives the
%% mock (or, by config, a real provider) with; absent it, the ask path has no mock
%% to drive and the run path is unchanged.
-spec start_link(#{socket := file:filename_all(),
                   model_config => term()}) ->
    {ok, pid()} | {error, term()}.
start_link(#{socket := Path} = Opts) ->
    ModelConfig = maps:get(model_config, Opts, undefined),
    Parent = self(),
    Pid = spawn_link(fun() -> listen(Parent, Path, ModelConfig) end),
    receive
        {Pid, listening} -> {ok, Pid};
        {Pid, {error, Reason}} -> {error, Reason}
    end.

listen(Parent, Path, ModelConfig) ->
    _ = unlink_stale(Path),
    case gen_tcp:listen(0, [{ifaddr, {local, Path}},
                            {packet, 4}, binary,
                            {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            Parent ! {self(), listening},
            accept_loop(ListenSocket, ModelConfig);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

%% Unlink only a *stale* leftover at Path -- a file no live server answers --
%% so a restart after a crash that left a socket file still binds, while a live
%% server's path is left alone (a second start_link then fails the bind rather
%% than stealing the path). Probe by connecting: if a server answers, the path
%% is live and untouched; if no file is there, or nothing answers, clear it.
unlink_stale(Path) ->
    case file:read_file_info(Path) of
        {ok, _} ->
            case gen_tcp:connect({local, Path}, 0,
                                 [binary, {active, false}], 200) of
                {ok, Probe} ->
                    gen_tcp:close(Probe);
                {error, _} ->
                    file:delete(Path)
            end;
        {error, _} ->
            ok
    end.

accept_loop(ListenSocket, ModelConfig) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            %% The accepted socket is owned by this accept-loop process. Hand it
            %% to the handler so socket events under `{active, once}' (the
            %% client-disconnect `{tcp_closed, Socket}') are delivered to the
            %% handler's mailbox -- the process that waits in `await_run' -- and
            %% not stranded here in the acceptor. The handler waits for `proceed'
            %% so it only touches the socket once it owns it. The handler carries
            %% the daemon's `model_config' so an ask request can drive the actor.
            Handler = spawn(fun() -> wait_then_handle(Socket, ModelConfig) end),
            ok = gen_tcp:controlling_process(Socket, Handler),
            Handler ! proceed,
            accept_loop(ListenSocket, ModelConfig);
        {error, closed} ->
            ok
    end.

wait_then_handle(Socket, ModelConfig) ->
    receive
        proceed -> handle(Socket, ModelConfig)
    end.

%% Per-connection handler, one process per accepted connection. It reads one
%% framed `(run ...)' request, drives a supervised run it owns directly, frames
%% the terminal `(result ...)' s-expr back, then closes. The socket is
%% `{packet, 4}', so the driver strips the length prefix on recv and prepends it
%% on send -- the payload here is the bare s-expr.
handle(Socket, ModelConfig) ->
    case gen_tcp:recv(Socket, 0, 60000) of
        {ok, Bytes} ->
            case handle_lisp_request(Bytes, Socket, ModelConfig) of
                noreply ->
                    gen_tcp:close(Socket);
                Reply ->
                    _ = gen_tcp:send(Socket, iolist_to_binary(Reply)),
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
handle_lisp_request(Bytes, Socket, ModelConfig) ->
    Compiled = try soma_lfe:compile(Bytes, #{})
               catch
                   Class:Reason ->
                       {error, [#{code => malformed_request,
                                  message => iolist_to_binary(
                                               io_lib:format("~p:~p",
                                                             [Class, Reason]))}]}
               end,
    case Compiled of
        {ok, #{run := #{steps := Steps}}} ->
            run_steps(Steps, Socket);
        {ok, #{ask := Ask}} ->
            handle_ask(Ask, ModelConfig);
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
handle_ask(Ask, ModelConfig) ->
    TaskId = mint_id("task"),
    CorrId = mint_id("corr"),
    Intent = maps:get(intent, Ask),
    Opts0 = #{actor_id => mint_id("actor"),
              model_config => ModelConfig,
              event_store => event_store_pid()},
    Opts1 = case maps:find(tool_policy, Ask) of
                {ok, Policy} -> Opts0#{tool_policy => Policy};
                error -> Opts0
            end,
    Opts2 = case maps:find(budget, Ask) of
                {ok, Budget} -> Opts1#{budget => Budget};
                error -> Opts1
            end,
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts2),
    Llm = mock_llm_opts(ModelConfig),
    Envelope = #{type => <<"ask">>,
                 payload => #{text => Intent},
                 task_id => TaskId,
                 correlation_id => CorrId,
                 llm => Llm},
    Result = case soma_actor:ask(ActorPid, Envelope, 60000) of
                 {ok, #{kind := reply, text := Text}} ->
                     #{status => completed,
                       task_id => TaskId,
                       correlation_id => CorrId,
                       outputs => #{reply => Text}};
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
             end,
    soma_lisp:render(Result).

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

%% Prepend a 4-byte big-endian length prefix to an s-expr payload, the wire frame
%% a client reads. `{packet, 4}' produces the same shape in the driver; this is
%% the pure, documented contract a non-Erlang client reproduces.
-spec frame(iodata()) -> iolist().
frame(Payload) ->
    Bin = iolist_to_binary(Payload),
    [<<(byte_size(Bin)):32/big>>, Bin].

%% Split the 4-byte big-endian length prefix off a frame, returning the payload.
-spec unframe(binary()) -> binary().
unframe(<<Len:32/big, Payload:Len/binary>>) ->
    Payload.
