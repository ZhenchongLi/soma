%% Interactive demo for the soma_actor agent-entity layer (v0.4).
%%
%% Where soma_demo.erl drives the execution core directly (session -> run ->
%% tool call), this drives the layer above it: a soma_actor that takes a
%% message, creates a task, runs it through soma_run, and returns a result.
%%
%% Usage from `rebar3 shell':
%%
%%   c("examples/soma_actor_demo").
%%   soma_actor_demo:ask_demo().      % ask/3 a steps envelope, block for the result
%%   soma_actor_demo:poll_demo().     % send/2 + poll status/result + by_correlation chain
%%   soma_actor_demo:cancel_demo().   % cancel a live task mid-run (cancellation is real)
%%   soma_actor_demo:survive_demo().  % a failing run does not kill the actor
%%
-module(soma_actor_demo).
-export([ask_demo/0, poll_demo/0, cancel_demo/0, survive_demo/0]).

%% -----------------------------------------------------------------------
%% Demo 1: ask/3 — synchronous request/reply
%%
%% Sends an envelope carrying one echo step and blocks the caller until the
%% run completes, returning the run's outputs.
%% -----------------------------------------------------------------------
ask_demo() ->
    {Actor, _Store} = setup(),
    Envelope = #{type    => <<"chat">>,
                 payload => #{text => <<"say hi">>},
                 steps   => [#{id => s1, tool => echo,
                               args => #{value => <<"hello soma">>}}]},
    io:format("~nask/3 (blocks until the run completes)...~n"),
    Result = soma_actor:ask(Actor, Envelope, 5000),
    io:format("  => ~p~n", [Result]).

%% -----------------------------------------------------------------------
%% Demo 2: send/2 + polling + the correlation chain
%%
%% Fires the task asynchronously (returns a task_id immediately while a 400ms
%% sleep step runs), polls status/result before and after completion, then
%% reads the whole task chain — actor.* AND run.* events — back out of the
%% event store under one correlation_id.
%% -----------------------------------------------------------------------
poll_demo() ->
    {Actor, Store} = setup(),
    Corr = <<"corr-demo-1">>,
    Envelope = #{type           => <<"chat">>,
                 payload        => #{},
                 correlation_id => Corr,
                 steps          => [#{id => s1, tool => sleep,
                                      args => #{ms => 400}}]},
    {ok, Task} = soma_actor:send(Actor, Envelope),
    io:format("~nsend/2 => task ~p (returned while the run is still going)~n", [Task]),
    io:format("  status now  : ~p~n", [soma_actor:get_task_status(Actor, Task)]),
    io:format("  result now  : ~p~n", [soma_actor:get_task_result(Actor, Task)]),
    ok = wait_status(Actor, Task, completed, 50),
    io:format("  status done : ~p~n", [soma_actor:get_task_status(Actor, Task)]),
    io:format("  result done : ~p~n", [soma_actor:get_task_result(Actor, Task)]),
    Events = soma_event_store:by_correlation(Store, Corr),
    io:format("~n--- full chain under correlation_id ~p ---~n", [Corr]),
    [io:format("  ~s~n", [maps:get(event_type, E)]) || E <- Events].

%% -----------------------------------------------------------------------
%% Demo 3: cancel a live task
%%
%% Starts a task whose step sleeps 30s, waits until it is running, then
%% cancels it. cancel/2 sends `cancel' to the run the actor owns; the run
%% kills the active tool worker for real and reports back. The task ends
%% `cancelled' and the actor stays alive.
%% -----------------------------------------------------------------------
cancel_demo() ->
    {Actor, _Store} = setup(),
    Envelope = #{type    => <<"chat">>,
                 payload => #{},
                 steps   => [#{id => s1, tool => sleep, args => #{ms => 30000}}]},
    {ok, Task} = soma_actor:send(Actor, Envelope),
    ok = wait_status(Actor, Task, running, 50),
    io:format("~ntask ~p is running; cancelling...~n", [Task]),
    ok = soma_actor:cancel(Actor, Task),
    ok = wait_status(Actor, Task, cancelled, 50),
    io:format("  status      : ~p~n", [soma_actor:get_task_status(Actor, Task)]),
    io:format("  actor alive : ~p~n", [is_process_alive(Actor)]).

%% -----------------------------------------------------------------------
%% Demo 4: a failing run does not kill the actor
%%
%% Runs the `fail' tool in error mode. The run fails; the actor records the
%% failure as data (status `failed'), stays alive, and still accepts the next
%% task — failure isolation by process boundary, not a poisoned actor.
%% -----------------------------------------------------------------------
survive_demo() ->
    {Actor, _Store} = setup(),
    Failing = #{type    => <<"chat">>,
                payload => #{},
                steps   => [#{id => s1, tool => fail,
                              args => #{mode => error, reason => boom}}]},
    {ok, Task} = soma_actor:send(Actor, Failing),
    ok = wait_status(Actor, Task, failed, 50),
    io:format("~ntask ~p failed; the actor absorbs it as data~n", [Task]),
    io:format("  status      : ~p~n", [soma_actor:get_task_status(Actor, Task)]),
    io:format("  actor alive : ~p~n", [is_process_alive(Actor)]),
    %% ...and the same actor still serves the next task:
    Next = #{type    => <<"chat">>,
             payload => #{},
             steps   => [#{id => s1, tool => echo,
                           args => #{value => <<"still here">>}}]},
    io:format("  next task   : ~p~n", [soma_actor:ask(Actor, Next, 5000)]).

%%% Internal helpers

%% Start the runtime (soma_run_sup + tool registry) and the soma_actor app,
%% an event store the actor and the runs it starts both write into, and one
%% actor. Returns {ActorPid, StorePid}. Safe to call from each demo:
%% ensure_all_started is idempotent; each demo gets a fresh store and actor.
setup() ->
    {ok, _} = application:ensure_all_started(soma_runtime),
    {ok, _} = application:ensure_all_started(soma_actor),
    {ok, Store} = soma_event_store:start_link(),
    {ok, Actor} = soma_actor_sup:start_actor(#{actor_id     => <<"demo-actor">>,
                                               model_config => #{},
                                               tool_policy  => #{},
                                               event_store  => Store}),
    {Actor, Store}.

%% Poll the task table until the task reaches the wanted status, or give up.
wait_status(_, _, _, 0) -> {error, timeout};
wait_status(Actor, Task, Want, N) ->
    case maps:get(status, soma_actor:get_task_status(Actor, Task), undefined) of
        Want -> ok;
        _    -> timer:sleep(50), wait_status(Actor, Task, Want, N - 1)
    end.
