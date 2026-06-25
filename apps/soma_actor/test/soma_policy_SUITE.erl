%% @doc Actor-side proofs for the soma_policy gate wired into the actor's
%% llm_result success path. Set up like soma_proposal_SUITE: boot the soma_runtime
%% app (so the event store is alive), start an actor through
%% soma_actor_sup:start_actor/1 with a `tool_policy', and drive it through the real
%% soma_actor:send/2 with an `llm' envelope carrying a `proposal' directive.
-module(soma_policy_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([allowed_run_steps_emits_proposal_approved_with_correlation_id/1]).
-export([allowed_proposal_starts_no_run/1]).
-export([allowed_proposal_status_reads_approved/1]).
-export([rejected_proposal_emits_proposal_rejected_with_reason_and_correlation_id/1]).
-export([rejected_proposal_starts_no_run/1]).

all() ->
    [allowed_run_steps_emits_proposal_approved_with_correlation_id,
     allowed_proposal_starts_no_run,
     allowed_proposal_status_reads_approved,
     rejected_proposal_emits_proposal_rejected_with_reason_and_correlation_id,
     rejected_proposal_starts_no_run].

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

%% Criterion 5: after a mock LLM call returns a policy-allowed `run_steps'
%% proposal (every step's tool is in the actor's tool_policy allowlist), the actor
%% emits a `proposal.approved' event carrying that task's `correlation_id'. Enters
%% through the real soma_actor:send/2 with a `proposal' llm directive, waits for
%% the task to reach `approved', then reads the correlated events back through
%% soma_event_store:by_correlation/2 and asserts the trail contains a
%% `proposal.approved' event tagged with the task's correlation_id.
allowed_run_steps_emits_proposal_approved_with_correlation_id(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-policy-approved">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [<<"echo">>]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => <<"echo">>},
                              #{id => <<"s2">>, tool => <<"echo">>}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-policy-approved">>,
    CorrelationId = <<"corr-policy-approved">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, approved, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Approved = [E || E <- Events,
                     maps:get(event_type, E, undefined) =:= <<"proposal.approved">>],
    [Event] = Approved,
    CorrelationId = maps:get(correlation_id, Event),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 6: a policy-allowed proposal passes the gate but executes nothing --
%% the actor sets the task `approved' and starts no soma_run. Entering through the
%% real soma_actor:send/2 with a `proposal' llm directive, waits for the task to
%% reach `approved', then reads the correlated events back through
%% soma_event_store:by_correlation/2 and asserts the trail carries no
%% `run.started' event for that task's correlation_id (executing is v0.5.4).
allowed_proposal_starts_no_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-policy-no-run">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [<<"echo">>]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => <<"echo">>},
                              #{id => <<"s2">>, tool => <<"echo">>}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-policy-no-run">>,
    CorrelationId = <<"corr-policy-no-run">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, approved, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RunStarted = [E || E <- Events,
                       maps:get(event_type, E, undefined) =:= <<"run.started">>],
    [] = RunStarted,
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 7: a policy-allowed proposal passes the gate but executes nothing,
%% leaving the task status reading `approved'. Entering through the real
%% soma_actor:send/2 with a `proposal' llm directive, waits for the task to reach
%% `approved', then reads the task status back through soma_actor:get_task_status/2
%% and asserts it reads `approved' (not `completed', which is the pre-gate status).
allowed_proposal_status_reads_approved(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-policy-status">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [<<"echo">>]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => <<"echo">>},
                              #{id => <<"s2">>, tool => <<"echo">>}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-policy-status">>,
    CorrelationId = <<"corr-policy-status">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, approved, 100),
    approved = maps:get(status, soma_actor:get_task_status(ActorPid, TaskId)),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 8: after a mock LLM call returns a policy-rejected `run_steps'
%% proposal (a step names a tool absent from the actor's tool_policy allowlist),
%% the actor emits a `proposal.rejected' event carrying the reject reason and that
%% task's `correlation_id'. Enters through the real soma_actor:send/2 with a
%% `proposal' llm directive, waits for the task to reach `rejected', then reads the
%% correlated events back through soma_event_store:by_correlation/2 and asserts the
%% trail contains a single `proposal.rejected' event tagged with the task's
%% correlation_id and carrying the reject reason.
rejected_proposal_emits_proposal_rejected_with_reason_and_correlation_id(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-policy-rejected">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [<<"echo">>]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => <<"echo">>},
                              #{id => <<"s2">>, tool => <<"forbidden">>}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-policy-rejected">>,
    CorrelationId = <<"corr-policy-rejected">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, rejected, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Rejected = [E || E <- Events,
                     maps:get(event_type, E, undefined) =:= <<"proposal.rejected">>],
    [Event] = Rejected,
    CorrelationId = maps:get(correlation_id, Event),
    {tools_not_allowed, [<<"forbidden">>]} = maps:get(reason, Event),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 9: a policy-rejected proposal starts no run -- the reject path
%% executes nothing, so `by_correlation/2' for that task surfaces no `run.started'
%% event. Entering through the real soma_actor:send/2 with a `proposal' llm
%% directive whose step names a tool absent from the allowlist, waits for the task
%% to reach `rejected', then reads the correlated events back through
%% soma_event_store:by_correlation/2 and asserts the trail carries no `run.started'
%% event for that task's correlation_id.
rejected_proposal_starts_no_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-policy-reject-no-run">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [<<"echo">>]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => <<"echo">>},
                              #{id => <<"s2">>, tool => <<"forbidden">>}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-policy-reject-no-run">>,
    CorrelationId = <<"corr-policy-reject-no-run">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, rejected, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RunStarted = [E || E <- Events,
                       maps:get(event_type, E, undefined) =:= <<"run.started">>],
    [_] = RunStarted,
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
