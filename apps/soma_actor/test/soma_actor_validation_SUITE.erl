-module(soma_actor_validation_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([malformed_steps_rejected_or_failed_not_running/1]).

all() ->
    [malformed_steps_rejected_or_failed_not_running].

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
