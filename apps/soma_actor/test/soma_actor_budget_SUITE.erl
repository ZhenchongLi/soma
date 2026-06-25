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
-export([actor_survives_budget_failure_takes_next_envelope/1]).
-export([parked_ask_on_budget_failed_task_gets_error/1]).
-export([by_correlation_surfaces_budget_failed_event_with_reason/1]).
-export([no_budget_field_executes_approved_run_steps_to_completed/1]).

all() ->
    [budget_zero_llm_calls_fails_task_with_reason,
     budget_zero_llm_calls_emits_no_llm_started,
     budget_max_steps_fails_oversized_proposal_with_reason,
     budget_max_steps_oversized_proposal_emits_no_run_started,
     budget_within_max_steps_proposal_completes,
     budget_failed_task_status_reads_failed,
     actor_survives_budget_failure_takes_next_envelope,
     parked_ask_on_budget_failed_task_gets_error,
     by_correlation_surfaces_budget_failed_event_with_reason,
     no_budget_field_executes_approved_run_steps_to_completed].

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

%% Criterion 7: after a budget failure the same actor accepts a later
%% within-budget envelope and drives it to `completed'. One actor with
%% `max_steps => 1': the first envelope's approved proposal carries two steps
%% (over the cap, so the task fails as data and the actor stays in `idle'), then
%% a second envelope's approved proposal carries one step (within the cap, so it
%% runs through the full decision loop to `completed'). Both envelopes go through
%% the real soma_actor:send/2 on the same actor pid; the test asserts the actor
%% is alive after the failure and that the second task reaches `completed'.
actor_survives_budget_failure_takes_next_envelope(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-survive">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_steps => 1},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    %% First envelope: a two-step proposal against max_steps of 1 -> over the
    %% cap, so the first task is budget-failed.
    OverProposal = #{kind => run_steps,
                     steps => [#{id => <<"s1">>, tool => echo,
                                args => #{value => <<"a">>}},
                               #{id => <<"s2">>, tool => echo,
                                args => #{value => <<"b">>}}]},
    FirstLlm = #{directive => proposal, output => OverProposal},
    FirstTaskId = <<"task-budget-survive-1">>,
    FirstEnvelope = #{type => <<"chat">>,
                      payload => #{text => <<"do it">>},
                      task_id => FirstTaskId,
                      correlation_id => <<"corr-budget-survive-1">>,
                      llm => FirstLlm},
    {ok, FirstTaskId} = soma_actor:send(ActorPid, FirstEnvelope),
    ok = wait_for_status(ActorPid, FirstTaskId, failed, 100),
    true = is_process_alive(ActorPid),
    %% Second envelope: a one-step proposal against max_steps of 1 -> within
    %% the cap, so the second task runs to completion on the same live actor.
    WithinProposal = #{kind => run_steps,
                       steps => [#{id => <<"s1">>, tool => echo,
                                  args => #{value => <<"c">>}}]},
    SecondLlm = #{directive => proposal, output => WithinProposal},
    SecondTaskId = <<"task-budget-survive-2">>,
    SecondEnvelope = #{type => <<"chat">>,
                       payload => #{text => <<"do it again">>},
                       task_id => SecondTaskId,
                       correlation_id => <<"corr-budget-survive-2">>,
                       llm => SecondLlm},
    {ok, SecondTaskId} = soma_actor:send(ActorPid, SecondEnvelope),
    ok = wait_for_status(ActorPid, SecondTaskId, completed, 100),
    Status = soma_actor:get_task_status(ActorPid, SecondTaskId),
    completed = maps:get(status, Status),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 8: a parked `ask' on a budget-failed task receives an `{error, _}'
%% reply. An actor with `budget => #{max_llm_calls => 0}' is driven through the
%% real soma_actor:ask/3 with an `llm' envelope. The budget check inside
%% maybe_start_llm_call/4 fails before any call starts, and the shared failure
%% helper must release the parked ask waiter `From' with
%% `{error, {budget_exceeded, max_llm_calls}}' rather than leaving the caller
%% blocked until the timeout. The actor stays alive.
parked_ask_on_budget_failed_task_gets_error(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-ask">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_llm_calls => 0},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => proposal,
            output => #{kind => reply, text => <<"hi">>}},
    TaskId = <<"task-budget-ask">>,
    CorrelationId = <<"corr-budget-ask">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    Reply = soma_actor:ask(ActorPid, Envelope, 1000),
    {error, {budget_exceeded, max_llm_calls}} = Reply,
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 9: soma_event_store:by_correlation/2 for a budget-failed task
%% surfaces its `actor.task.failed' event carrying the budget reason. Drives the
%% `max_llm_calls => 0' budget failure through the real soma_actor:send/2 so the
%% shared failure helper emits `actor.task.failed' with the budget reason, waits
%% for the terminal `failed' status, then reads the full chain back through
%% soma_event_store:by_correlation/2 and asserts exactly one `actor.task.failed'
%% event whose `reason' is `{budget_exceeded, max_llm_calls}'.
by_correlation_surfaces_budget_failed_event_with_reason(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-budget-trail">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             budget => #{max_llm_calls => 0},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => proposal,
            output => #{kind => reply, text => <<"hi">>}},
    TaskId = <<"task-budget-trail">>,
    CorrelationId = <<"corr-budget-trail">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    [Failed] = [E || E <- Events,
                     maps:get(event_type, E, undefined) =:= <<"actor.task.failed">>],
    {budget_exceeded, max_llm_calls} = maps:get(reason, Failed),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 10: an actor started with NO `budget' field still executes an
%% approved `run_steps' proposal all the way to `completed' -- the default is
%% unchanged from v0.5.4. With no budget, both spend-point checks see an
%% unlimited cap: maybe_start_llm_call/4 starts the call, and the `run_steps'
%% branch's step-count gate passes regardless of count, so a run starts via
%% start_owned_run/4 and reaches `completed'. Drives the envelope through the
%% real soma_actor:send/2 and reads the terminal `completed' status back through
%% get_task_status/2.
no_budget_field_executes_approved_run_steps_to_completed(_Config) ->
    Store = event_store_pid(),
    %% No `budget' key at all -- the default-unchanged path.
    Opts = #{actor_id => <<"actor-no-budget">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}},
                              #{id => <<"s2">>, tool => echo,
                               args => #{value => <<"b">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-no-budget">>,
    CorrelationId = <<"corr-no-budget">>,
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
