-module(soma_actor_startup_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([actor_only_start_runs_steps_to_terminal/1]).

all() ->
    [actor_only_start_runs_steps_to_terminal].

%% Start ONLY the soma_actor application -- nothing else. This is the exact
%% contract criterion 1 names: `application:ensure_all_started(soma_actor)` and
%% nothing more. It must NOT start soma_runtime by hand the way the run-
%% integration cases in soma_actor_SUITE do; if it did, the test would pass even
%% with the soma_actor.app.src dependency reverted and would prove nothing.
init_per_testcase(actor_only_start_runs_steps_to_terminal, Config) ->
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(actor_only_start_runs_steps_to_terminal, _Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    ok;
end_per_testcase(_TestCase, _Config) ->
    ok.

%% Criterion 1: after `application:ensure_all_started(soma_actor)` and nothing
%% else, submitting a steps envelope through the documented quickstart runs to a
%% terminal task result instead of crashing the actor with a `noproc` for
%% `soma_run_sup`. Starting the actor app alone must bring up soma_run_sup (the
%% runtime), so the steps envelope starts a real soma_run that reaches
%% run.completed and the actor records the task as `completed`. The test starts
%% only the actor app -- it never calls ensure_all_started(soma_runtime).
actor_only_start_runs_steps_to_terminal(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-startup">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-startup">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    true = is_process_alive(Pid),
    completed = wait_for_task_status(Pid, TaskId, completed, 100),
    ok.

%% Reads the runtime's event store pid from the running soma_sup tree.
event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

%% Polls the actor's task table until the task reaches the target status,
%% returning the observed status. The tasks table is the fifth record field
%% (element position 6), keyed by task_id.
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
