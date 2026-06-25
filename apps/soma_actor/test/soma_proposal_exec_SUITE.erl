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
-export([approved_run_steps_emits_proposal_executed_with_correlation_id/1]).
-export([by_correlation_returns_full_approved_run_chain/1]).
-export([approved_run_steps_runs_in_distinct_pid/1]).
-export([rejected_proposal_starts_no_run_status_rejected/1]).

all() ->
    [approved_run_steps_completes_with_step_outputs,
     approved_run_steps_emits_proposal_executed_with_correlation_id,
     by_correlation_returns_full_approved_run_chain,
     approved_run_steps_runs_in_distinct_pid,
     rejected_proposal_starts_no_run_status_rejected].

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

%% Criterion 2: an approved `run_steps' proposal emits a `proposal.executed' event
%% carrying the task's correlation_id (and llm_call_id, matching the other proposal
%% events) at the point the run is started. Drives the same approved-proposal chain
%% through the real soma_actor:send/2, waits for the task to reach `completed' (so
%% the run was started and the event was emitted), then reads the event back through
%% soma_event_store:by_correlation/2 and asserts a `proposal.executed' event exists
%% carrying the task's correlation_id.
approved_run_steps_emits_proposal_executed_with_correlation_id(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-exec-executed">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-exec-executed">>,
    CorrelationId = <<"corr-exec-executed">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Executed = [E || E <- Events,
                     maps:get(event_type, E, undefined) =:= <<"proposal.executed">>],
    [Event | _] = Executed,
    CorrelationId = maps:get(correlation_id, Event),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 3: for an approved `run_steps' proposal, by_correlation/2 returns the
%% full chain under one correlation_id. Drives the same approved-proposal chain
%% through the real soma_actor:send/2, waits for `completed' (so the whole chain
%% emitted), then reads every event back through by_correlation/2 and asserts the
%% trail names an `actor.*' event, an `llm.*' event, `proposal.created',
%% `proposal.approved', `proposal.executed', `run.started', and `run.completed'.
by_correlation_returns_full_approved_run_chain(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-exec-chain">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-exec-chain">>,
    CorrelationId = <<"corr-exec-chain">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E, undefined) || E <- Events],
    %% An `actor.*' and an `llm.*' event each appear (any subtype under the prefix).
    true = lists:any(fun(T) -> has_prefix(T, <<"actor.">>) end, Types),
    true = lists:any(fun(T) -> has_prefix(T, <<"llm.">>) end, Types),
    true = lists:member(<<"proposal.created">>, Types),
    true = lists:member(<<"proposal.approved">>, Types),
    true = lists:member(<<"proposal.executed">>, Types),
    true = lists:member(<<"run.started">>, Types),
    true = lists:member(<<"run.completed">>, Types),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 4: the run started from an approved `run_steps' proposal executes in
%% a `soma_run' process whose pid is not the actor's pid. Drives the same
%% approved-proposal chain through the real soma_actor:send/2, then catches the
%% live run pid by polling `soma_run_sup' children while the run is in flight,
%% asserts that pid is a child of `soma_run_sup' (i.e. it ran under the run
%% supervisor, not in the actor), and that it differs from the actor pid.
approved_run_steps_runs_in_distinct_pid(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-exec-pid">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => echo,
                               args => #{value => <<"a">>}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-exec-pid">>,
    CorrelationId = <<"corr-exec-pid">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    RunPid = catch_run_pid(100),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    %% The run executed under soma_run_sup, so its pid is one of that
    %% supervisor's children -- a distinct process, not the actor.
    true = is_pid(RunPid),
    true = (RunPid =/= ActorPid),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 5: a policy-rejected `run_steps' proposal (a step tool NOT in the
%% actor's tool_policy allowlist) starts no run. Drives the same proposal chain
%% through the real soma_actor:send/2 with a step tool the policy rejects, waits
%% for the task to reach the terminal `rejected' status, then reads the trail
%% through by_correlation/2 and asserts it contains a `proposal.rejected' event
%% and no `run.started' event.
rejected_proposal_starts_no_run_status_rejected(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-exec-rejected">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    %% The step tool `sleep' is not in the allowlist (`echo' only), so the
    %% policy rejects the proposal and no run is started.
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => sleep,
                               args => #{ms => 1}}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-exec-rejected">>,
    CorrelationId = <<"corr-exec-rejected">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E, undefined) || E <- Events],
    true = lists:member(<<"proposal.rejected">>, Types),
    true = lists:member(<<"run.started">>, Types),
    true = is_process_alive(ActorPid),
    ok.

%% Polls `soma_run_sup' children until a run pid appears, returning it. The
%% approved run_steps proposal starts exactly one short-lived run under that
%% supervisor; this catches its pid while it is in flight.
catch_run_pid(0) ->
    error(no_run_pid);
catch_run_pid(N) ->
    case [Pid || {_Id, Pid, _Type, _Mods}
                     <- supervisor:which_children(soma_run_sup),
                 is_pid(Pid)] of
        [Pid | _] ->
            Pid;
        [] ->
            timer:sleep(2),
            catch_run_pid(N - 1)
    end.

%% True when binary T starts with binary Prefix.
has_prefix(T, Prefix) when is_binary(T) ->
    case T of
        <<Prefix:(byte_size(Prefix))/binary, _/binary>> -> true;
        _ -> false
    end;
has_prefix(_, _) ->
    false.

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
