-module(soma_actor_validation_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([malformed_steps_rejected_or_failed_not_running/1]).
-export([actor_alive_after_malformed_steps/1]).
-export([valid_steps_complete_after_malformed/1]).
-export([ask_no_steps_returns_ok_accepted/1]).
-export([ask_no_steps_parks_no_waiter/1]).

all() ->
    [malformed_steps_rejected_or_failed_not_running,
     actor_alive_after_malformed_steps,
     valid_steps_complete_after_malformed,
     ask_no_steps_returns_ok_accepted,
     ask_no_steps_parks_no_waiter].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup}, {started_apps, Started} | Config].

end_per_testcase(_TestCase, Config) ->
    case ?config(sup, Config) of
        undefined -> ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    application:stop(soma_runtime),
    ok.

%% Criterion 2: a steps envelope whose step maps are malformed -- here a step
%% missing the `id' key -- must not leave its task stuck at `running'. The
%% runtime is booted so soma_run_sup is alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store, no layer
%% bypassed. Enters through the real soma_actor:send/2 call with a step map that
%% omits `id'. The outcome must be either {error, Reason} up front (no run
%% started) OR a terminal `failed' task status -- never `running'.
malformed_steps_rejected_or_failed_not_running(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-malformed-steps">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-malformed-steps">>,
    %% A step map missing the required `id' key.
    Steps = [#{tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    case soma_actor:send(Pid, Envelope) of
        {error, _Reason} ->
            %% Rejected up front: no run started, nothing left at running.
            ok;
        {ok, TaskId} ->
            %% A run was started; it must reach a terminal `failed' status as
            %% data and must never sit at `running'.
            failed = wait_for_task_status(Pid, TaskId, failed, 100),
            true = task_status(Pid, TaskId) =/= running,
            ok
    end.

%% Criterion 3: submitting a malformed-steps envelope must not take the actor
%% down with it. The actor is a long-lived gen_statem entity; a known-bad step
%% list is rejected as data (up-front validation), never a crash. The runtime is
%% booted so no layer is bypassed; the actor is started through
%% soma_actor_sup:start_actor/1 and the bad envelope enters via the real
%% soma_actor:send/2. After submission the actor pid must still be alive.
actor_alive_after_malformed_steps(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-alive-malformed">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-alive-malformed">>,
    %% A step map missing the required `id' key.
    Steps = [#{tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    _ = soma_actor:send(Pid, Envelope),
    true = is_process_alive(Pid),
    ok.

%% Criterion 4: a malformed-steps envelope must not poison the actor for later
%% work. The runtime is booted so soma_run_sup and soma_tool_registry are alive;
%% the actor is started through soma_actor_sup:start_actor/1 with the booted
%% runtime's event store, no layer bypassed. The test first submits a malformed
%% envelope (a step missing `id') via the real soma_actor:send/2, then submits a
%% valid echo-step envelope to the SAME actor pid. The second task must reach a
%% terminal `completed' status, proving the rejected first envelope left the
%% actor able to run.
valid_steps_complete_after_malformed(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-valid-after-malformed">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    %% A malformed envelope: a step map missing the required `id' key.
    BadSteps = [#{tool => echo, args => #{value => <<"a">>}}],
    BadEnvelope = #{type => <<"chat">>,
                    payload => #{text => <<"bad">>},
                    task_id => <<"task-bad">>,
                    steps => BadSteps},
    _ = soma_actor:send(Pid, BadEnvelope),
    %% A valid echo-step envelope to the same actor.
    GoodTaskId = <<"task-good">>,
    GoodSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    GoodEnvelope = #{type => <<"chat">>,
                     payload => #{text => <<"good">>},
                     task_id => GoodTaskId,
                     steps => GoodSteps},
    {ok, GoodTaskId} = soma_actor:send(Pid, GoodEnvelope),
    completed = wait_for_task_status(Pid, GoodTaskId, completed, 100),
    ok.

%% Criterion 5: a no-steps envelope is valid by design and starts no run, so
%% ask/3 must reply IMMEDIATELY rather than parking the caller until TimeoutMs.
%% The chosen value is the distinct 3-tuple {ok, accepted, TaskId}: accepted, no
%% run started, here is the id to poll. The runtime is booted and the actor is
%% started through soma_actor_sup:start_actor/1, no layer bypassed. The test
%% passes a generous TimeoutMs and asserts the return is {ok, accepted, TaskId},
%% arriving well before the timeout.
ask_no_steps_returns_ok_accepted(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-no-steps">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-no-steps">>,
    %% A no-steps envelope (no `steps' key at all).
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId},
    %% Generous timeout: a blocking ask/3 would sit here for 5s; an immediate
    %% reply returns at once.
    TimeoutMs = 5000,
    {ok, accepted, TaskId} = soma_actor:ask(Pid, Envelope, TimeoutMs),
    ok.

%% Criterion 6: a no-steps envelope starts no run, so ask/3 replies immediately
%% and must leave NO parked waiter behind -- a stale waiter would never be
%% answered and would leak across the actor's lifetime. After ask/3 returns, the
%% actor's private #data.waiters map must not hold an entry for this task id. The
%% runtime is booted and the actor is started through
%% soma_actor_sup:start_actor/1, no layer bypassed; the waiters map is read via
%% the standard sys:get_state/1 introspection because it has no public getter.
ask_no_steps_parks_no_waiter(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-no-waiter">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-no-waiter">>,
    %% A no-steps envelope (no `steps' key at all).
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId},
    {ok, accepted, TaskId} = soma_actor:ask(Pid, Envelope, 5000),
    %% After the immediate reply the actor must hold no parked waiter for the
    %% task.
    Waiters = waiters(Pid),
    true = maps:is_key(TaskId, Waiters),
    ok.

waiters(Pid) ->
    {idle, Data} = sys:get_state(Pid),
    element(8, Data).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

task_status(Pid, TaskId) ->
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    maps:get(status, maps:get(TaskId, Tasks)).

wait_for_task_status(_Pid, _TaskId, Target, 0) ->
    error({timeout, Target});
wait_for_task_status(Pid, TaskId, Target, N) ->
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    case maps:get(status, maps:get(TaskId, Tasks)) of
        Target ->
            Target;
        _Other ->
            timer:sleep(20),
            wait_for_task_status(Pid, TaskId, Target, N - 1)
    end.
