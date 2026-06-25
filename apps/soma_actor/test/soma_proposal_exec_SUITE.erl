%% @doc Actor-side proofs that an approved `run_steps' proposal actually executes
%% (v0.5.4, node A: intent -> LLM -> proposal -> policy -> run). Set up like
%% soma_policy_SUITE: boot the soma_runtime app (so soma_run_sup and the event
%% store are alive), start an actor through soma_actor_sup:start_actor/1 with a
%% `tool_policy', and drive it through the real soma_actor:send/2 with an `llm'
%% envelope carrying a `proposal' directive. Each proof reads outcomes back
%% through get_task_status/2, get_task_result/2, and
%% soma_event_store:by_correlation/2.
-module(soma_proposal_exec_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([approved_run_steps_completes_with_step_outputs/1]).

all() ->
    [approved_run_steps_completes_with_step_outputs].

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

%% Criterion 1: an `llm' envelope whose mock returns a policy-approved `run_steps'
%% proposal (every step tool allowed) reaches task status `completed', and
%% get_task_result/2 returns the run's step outputs. Enters through the real
%% soma_actor:send/2 with a `proposal' llm directive, waits for the task to reach
%% `completed' (the run finished and its outputs were stored), then asserts
%% get_task_result/2 returns the step outputs keyed by step id.
approved_run_steps_completes_with_step_outputs(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-exec-completed">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-exec-completed">>,
    CorrelationId = <<"corr-exec-completed">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    {ok, Outputs} = soma_actor:get_task_result(ActorPid, TaskId),
    %% The single echo step s1 echoes its args unchanged, so the run's Outputs
    %% map is keyed by the step id with the echoed args as the value.
    #{<<"s1">> := #{value := <<"a">>}} = Outputs,
    true = is_process_alive(ActorPid),
    ok.

%% Polls get_task_status until the task reaches the given status.
wait_for_status(_ActorPid, TaskId, Status, 0) ->
    error({timeout, TaskId, Status});
wait_for_status(ActorPid, TaskId, Status, N) ->
    case maps:get(status, soma_actor:get_task_status(ActorPid, TaskId)) of
        Status ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_status(ActorPid, TaskId, Status, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
