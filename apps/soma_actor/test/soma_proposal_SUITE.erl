%% @doc Actor-side proofs for soma_proposal normalization wired into the actor's
%% llm_result success path. Set up like soma_llm_call_SUITE: boot the soma_runtime
%% app (so the event store is alive), start an actor through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store, and drive it
%% through the real soma_actor:send/2 with an `llm' envelope carrying a `proposal'
%% directive.
-module(soma_proposal_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([reply_proposal_stored_as_task_result/1]).
-export([reply_proposal_emits_proposal_created_with_correlation_id/1]).
-export([run_steps_proposal_starts_no_run/1]).
-export([malformed_proposal_marks_task_failed/1]).
-export([actor_survives_malformed_proposal_takes_next_send/1]).
-export([by_correlation_returns_proposal_actor_and_llm_events/1]).

all() ->
    [reply_proposal_stored_as_task_result,
     reply_proposal_emits_proposal_created_with_correlation_id,
     run_steps_proposal_starts_no_run,
     malformed_proposal_marks_task_failed,
     actor_survives_malformed_proposal_takes_next_send,
     by_correlation_returns_proposal_actor_and_llm_events].

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

%% Criterion 9: after a mock LLM call returns a valid `reply' proposal,
%% get_task_result/2 for that task returns the normalized proposal. Enters through
%% the real soma_actor:send/2 with a `proposal' llm directive carrying a raw reply
%% proposal map, waits for the task to reach `completed', then asserts
%% get_task_result/2 returns {ok, Proposal} where Proposal is the value
%% soma_proposal:normalize/1 produces for that raw proposal -- the normalized
%% proposal, not the raw output.
reply_proposal_stored_as_task_result(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-proposal-reply">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => reply, text => <<"a normalized reply">>},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-proposal-reply">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    {ok, Proposal} = soma_proposal:normalize(RawProposal),
    {ok, Proposal} = soma_actor:get_task_result(ActorPid, TaskId),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 10: after a mock LLM call returns a valid `reply' proposal, the actor
%% emits a `proposal.created' event carrying that task's `correlation_id'. Enters
%% through the real soma_actor:send/2 with a `proposal' llm directive, waits for
%% the task to complete, then reads the correlated events back through
%% soma_event_store:by_correlation/2 and asserts exactly that trail contains a
%% `proposal.created' event tagged with the task's correlation_id.
reply_proposal_emits_proposal_created_with_correlation_id(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-proposal-created">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => reply, text => <<"a normalized reply">>},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-proposal-created">>,
    CorrelationId = <<"corr-proposal-created">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Created = [E || E <- Events,
                    maps:get(event_type, E, undefined) =:= <<"proposal.created">>],
    [Event] = Created,
    CorrelationId = maps:get(correlation_id, Event),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 11: after a mock LLM call returns a valid `run_steps' proposal (each
%% step a map with `id' and `tool'), the task's event trail contains no
%% `run.started' event -- the proposed steps are recorded as the task result, not
%% run. Enters through the real soma_actor:send/2 with a `proposal' llm directive
%% carrying a raw run_steps proposal, waits for the task to complete, then scans
%% the correlated events and asserts none has type `run.started'.
run_steps_proposal_starts_no_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-proposal-run-steps">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => run_steps,
                    steps => [#{id => <<"s1">>, tool => <<"echo">>},
                              #{id => <<"s2">>, tool => <<"echo">>}]},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-proposal-run-steps">>,
    CorrelationId = <<"corr-proposal-run-steps">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RunStarted = [E || E <- Events,
                       maps:get(event_type, E, undefined) =:= <<"run.started">>],
    [] = RunStarted,
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 12: after a mock LLM call returns a proposal candidate (a map with a
%% `kind' tag) that fails soma_proposal:normalize/1, the task status reads `failed'.
%% Enters through the real soma_actor:send/2 with a `proposal' llm directive
%% carrying a malformed proposal -- a `reply' proposal with no `text' -- waits for
%% the task to reach `failed', and asserts the actor stays alive.
malformed_proposal_marks_task_failed(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-proposal-malformed">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => reply},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-proposal-malformed">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    {error, _} = soma_proposal:normalize(RawProposal),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 13: after a task fails on a malformed proposal, the actor process is
%% still alive and accepts the next soma_actor:send/2 envelope. Sends a malformed
%% proposal, waits for that task to reach `failed', then asserts the same actor pid
%% is still alive and a second soma_actor:send/2 to it returns {ok, TaskId2}.
actor_survives_malformed_proposal_takes_next_send(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-proposal-survives">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => reply},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-proposal-survives-1">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    true = is_process_alive(ActorPid),
    TaskId2 = <<"task-proposal-survives-2">>,
    GoodProposal = #{kind => reply, text => <<"a normalized reply">>},
    Llm2 = #{directive => proposal, output => GoodProposal},
    Envelope2 = #{type => <<"chat">>,
                  payload => #{text => <<"again">>},
                  task_id => TaskId2,
                  llm => Llm2},
    {ok, TaskId2} = soma_actor:send(ActorPid, Envelope2),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 14: for the task's correlation_id, soma_event_store:by_correlation/2
%% returns the `proposal.created' event together with at least one `actor.*' event
%% and at least one `llm.*' event. Drives the real actor with a valid `reply'
%% proposal directive, waits for the task to complete, reads the correlated events
%% back, and partitions them by event_type prefix.
by_correlation_returns_proposal_actor_and_llm_events(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-proposal-trail">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => reply, text => <<"a normalized reply">>},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-proposal-trail">>,
    CorrelationId = <<"corr-proposal-trail">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E, undefined) || E <- Events],
    ProposalCreated = [T || T <- Types, T =:= <<"proposal.created">>],
    ActorEvents = [T || T <- Types, has_prefix(T, <<"actor.">>)],
    LlmEvents = [T || T <- Types, has_prefix(T, <<"llm.">>)],
    %% staged red: deliberately wrong expected value
    [] = ProposalCreated,
    true = length(ActorEvents) >= 1,
    true = length(LlmEvents) >= 1,
    true = is_process_alive(ActorPid),
    ok.

%% Whether Bin starts with Prefix (binary, byte-wise).
has_prefix(Bin, Prefix) when is_binary(Bin) ->
    PSize = byte_size(Prefix),
    case Bin of
        <<Prefix:PSize/binary, _/binary>> -> true;
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
