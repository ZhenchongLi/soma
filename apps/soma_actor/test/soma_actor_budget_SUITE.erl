%% @doc Actor-side proofs for v0.5.5 budget & loop limits: a budget cap
%% exhausted at one of the actor's spend points fails the task as data, not the
%% actor. Set up like soma_proposal_exec_SUITE: boot the soma_runtime app (so
%% soma_run_sup and the event store are alive), start an actor through
%% soma_actor_sup:start_actor/1 with a `budget' (and a `tool_policy' where a
%% proposal is involved), and drive it through the real soma_actor:send/2. Each
%% proof reads outcomes back through get_task_status/2 and
%% soma_event_store:by_correlation/2.
-module(soma_actor_budget_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([budget_zero_llm_calls_fails_task_with_reason/1]).
-export([budget_zero_llm_calls_emits_no_llm_started/1]).
-export([budget_max_steps_fails_oversized_proposal_with_reason/1]).
-export([budget_max_steps_oversized_proposal_emits_no_run_started/1]).
-export([budget_within_max_steps_proposal_completes/1]).
-export([budget_failed_task_status_reads_failed/1]).

all() ->
    [budget_zero_llm_calls_fails_task_with_reason,
     budget_zero_llm_calls_emits_no_llm_started,
     budget_max_steps_fails_oversized_proposal_with_reason,
     budget_max_steps_oversized_proposal_emits_no_run_started,
     budget_within_max_steps_proposal_completes,
     budget_failed_task_status_reads_failed].

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

%% Criterion 1: an actor started with `budget => #{max_llm_calls => 0}' fails an
%% `llm' envelope's task with reason `{budget_exceeded, max_llm_calls}'. The task
%% LLM-call count is already at the cap before the first call, so
%% maybe_start_llm_call/4 makes no call and fails the task through the shared
%% failure path. Drives the envelope through the real soma_actor:send/2 and reads
%% the terminal `failed' status and reason back through get_task_status/2.
budget_zero_llm_calls_fails_task_with_reason(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-zero">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_llm_calls => 0},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => proposal,
            output => #{kind => reply, text => <<"hi">>}},
    TaskId = <<"task-budget-zero">>,
    CorrelationId = <<"corr-budget-zero">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    Status = soma_actor:get_task_status(ActorPid, TaskId),
    {budget_exceeded, max_llm_calls} = maps:get(reason, Status),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 2: in that same `max_llm_calls => 0' case the actor makes no LLM
%% call, so the task's event trail carries no `llm.started' event. The budget
%% check in maybe_start_llm_call/4 returns through the shared failure path before
%% the `emit "llm.started"' call. Drives the envelope through the real
%% soma_actor:send/2, waits for the terminal `failed' status, then reads the trail
%% through soma_event_store:by_correlation/2 and asserts no `llm.started' event.
budget_zero_llm_calls_emits_no_llm_started(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-zero-no-llm">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_llm_calls => 0},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => proposal,
            output => #{kind => reply, text => <<"hi">>}},
    TaskId = <<"task-budget-zero-no-llm">>,
    CorrelationId = <<"corr-budget-zero-no-llm">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E, undefined) || E <- Events],
    false = lists:member(<<"llm.started">>, Types),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 3: an actor started with `budget => #{max_steps => N}' fails the task
%% of an approved `run_steps' proposal carrying more than N steps with reason
%% `{budget_exceeded, max_steps}'. The proposal arrives through the real mock
%% worker, passes policy (every step tool is allowed), then the step-count gate in
%% the `run_steps' branch sees a count over the cap and fails the task through the
%% shared failure path -- no run is started. Drives the envelope through the real
%% soma_actor:send/2 and reads the terminal `failed' status and reason back through
%% get_task_status/2.
budget_max_steps_fails_oversized_proposal_with_reason(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-steps">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_steps => 1},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    %% Two steps against a max_steps of 1: over the cap, so the proposal is
    %% budget-failed before any run starts.
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}},
                              #{id => <<"s2">>, tool => echo,
                               args => #{value => <<"b">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-budget-steps">>,
    CorrelationId = <<"corr-budget-steps">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    Status = soma_actor:get_task_status(ActorPid, TaskId),
    {budget_exceeded, max_steps} = maps:get(reason, Status),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 4: in that same `max_steps => N' over-cap case the actor starts no
%% run, so the task's event trail carries no `run.started' event. The step-count
%% gate in the `run_steps' branch returns through the shared failure path before
%% the `emit "proposal.executed"' and start_owned_run/4 calls. Drives the
%% envelope through the real soma_actor:send/2, waits for the terminal `failed'
%% status, then reads the trail through soma_event_store:by_correlation/2 and
%% asserts no `run.started' event.
budget_max_steps_oversized_proposal_emits_no_run_started(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-steps-no-run">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_steps => 1},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}},
                              #{id => <<"s2">>, tool => echo,
                               args => #{value => <<"b">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-budget-steps-no-run">>,
    CorrelationId = <<"corr-budget-steps-no-run">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E, undefined) || E <- Events],
    false = lists:member(<<"run.started">>, Types),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 5: an actor started with `budget => #{max_steps => N}' executes an
%% approved `run_steps' proposal carrying fewer than N steps all the way to
%% `completed'. The proposal arrives through the real mock worker, passes policy,
%% and the step-count gate in the `run_steps' branch sees a count within the cap,
%% so a run starts via start_owned_run/4 and reaches `completed'. Drives the
%% envelope through the real soma_actor:send/2 and reads the terminal `completed'
%% status back through get_task_status/2.
budget_within_max_steps_proposal_completes(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-within">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_steps => 3},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    %% Two steps against a max_steps of 3: within the cap, so the proposal runs.
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}},
                              #{id => <<"s2">>, tool => echo,
                               args => #{value => <<"b">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-budget-within">>,
    CorrelationId = <<"corr-budget-within">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Status = soma_actor:get_task_status(ActorPid, TaskId),
    completed = maps:get(status, Status),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 6: a budget-failed task reads `failed' through get_task_status/2.
%% Drives a budget failure (the `max_llm_calls => 0' case) through the real
%% soma_actor:send/2, waits for the terminal status, then reads the status map
%% back through get_task_status/2 and asserts the `status' field is `failed'.
budget_failed_task_status_reads_failed(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-status">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_llm_calls => 0},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => proposal,
            output => #{kind => reply, text => <<"hi">>}},
    TaskId = <<"task-budget-status">>,
    CorrelationId = <<"corr-budget-status">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    Status = soma_actor:get_task_status(ActorPid, TaskId),
    failed = maps:get(status, Status),
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
