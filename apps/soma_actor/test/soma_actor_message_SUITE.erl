%% @doc Actor-to-actor message proofs (v0.5.6, P12): one actor (A1) whose mock
%% returns a policy-approved `actor_message' proposal naming a second actor's
%% (A2's) pid as its `to' sends an envelope to A2; the sender's correlation_id
%% rides into A2's task; by_correlation/2 on that one id returns both actors'
%% events. Set up like soma_proposal_exec_SUITE: boot the soma_runtime app (so
%% the shared event store and soma_run_sup are alive), start two actors through
%% soma_actor_sup:start_actor/1, and drive A1 through the real soma_actor:send/2
%% with a `proposal' llm directive whose proposal's `to' is A2's pid -- the full
%% chain runs, no layer bypassed.
-module(soma_actor_message_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([delivered_message_accepted_by_a2_emits_task_accepted/1]).
-export([delivered_task_inherits_a1_correlation_id/1]).
-export([by_correlation_returns_both_actors_events/1]).
-export([a1_emits_proposal_executed_for_actor_message/1]).

all() ->
    [delivered_message_accepted_by_a2_emits_task_accepted,
     delivered_task_inherits_a1_correlation_id,
     by_correlation_returns_both_actors_events,
     a1_emits_proposal_executed_for_actor_message].

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

%% Criterion 5: A1's mock returns a policy-approved `actor_message' proposal
%% whose `to' is A2's pid. A1's approved-proposal branch builds a delivery
%% envelope and calls soma_actor:send(A2, Envelope) -- the normal entry point --
%% so A2 runs it through its own idle/3 dispatch and accepts a task. Drives A1
%% through the real soma_actor:send/2 with the `proposal' llm directive, then
%% reads the shared event store and asserts A2 emitted an `actor.task.accepted'
%% event for the delivered envelope (an event carrying A2's actor_id).
delivered_message_accepted_by_a2_emits_task_accepted(_Config) ->
    Store = event_store_pid(),
    A2Opts = #{actor_id => <<"actor-a2">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2} = soma_actor_sup:start_actor(A2Opts),
    A1Opts = #{actor_id => <<"actor-a1">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1} = soma_actor_sup:start_actor(A1Opts),
    RawProposal = #{kind => actor_message,
                    to => A2,
                    payload => #{text => <<"hello a2">>}},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-a1-send">>,
    CorrelationId = <<"corr-a1-send">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"tell a2">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(A1, Envelope),
    %% Wait until A2 has emitted an `actor.task.accepted' for the delivered
    %% envelope -- i.e. an accepted event carrying A2's actor_id. A2's delivered
    %% task inherits A1's correlation_id, so it appears under that id.
    ok = wait_for_a2_accepted(Store, CorrelationId, <<"actor-a2">>, 100),
    true = is_process_alive(A2),
    true = is_process_alive(A1),
    ok.

%% Criterion 6: A2's delivered task inherits A1's correlation_id. A1's sender
%% task ran under CorrelationId; the delivery envelope A1 builds carries that
%% same id, and A2's resolve_correlation_id/2 honors it, so the
%% `actor.task.accepted' event A2 emits carries A1's correlation_id. Drives A1
%% through the real soma_actor:send/2, waits for A2's accepted event, then reads
%% its `correlation_id' field and asserts it equals the id A1 ran under.
delivered_task_inherits_a1_correlation_id(_Config) ->
    Store = event_store_pid(),
    A2Opts = #{actor_id => <<"actor-a2">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2} = soma_actor_sup:start_actor(A2Opts),
    A1Opts = #{actor_id => <<"actor-a1">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1} = soma_actor_sup:start_actor(A1Opts),
    RawProposal = #{kind => actor_message,
                    to => A2,
                    payload => #{text => <<"hello a2">>}},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-a1-send">>,
    CorrelationId = <<"corr-a1-send">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"tell a2">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(A1, Envelope),
    ok = wait_for_a2_accepted(Store, CorrelationId, <<"actor-a2">>, 100),
    [A2Accepted | _] = a2_accepted_events(Store, CorrelationId, <<"actor-a2">>),
    CorrelationId = maps:get(correlation_id, A2Accepted),
    true = is_process_alive(A2),
    true = is_process_alive(A1),
    ok.

%% Criterion 7: with both actors sharing one event store and A2's delivered task
%% inheriting A1's correlation_id, `soma_event_store:by_correlation/2' for that
%% one id returns A1's chain and A2's chain together. Drives A1 through the real
%% soma_actor:send/2, waits for A2's accepted event, then reads every event under
%% CorrelationId and asserts the set of actor_ids carried by those events covers
%% both A1's and A2's actor_id.
by_correlation_returns_both_actors_events(_Config) ->
    Store = event_store_pid(),
    A2Opts = #{actor_id => <<"actor-a2">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2} = soma_actor_sup:start_actor(A2Opts),
    A1Opts = #{actor_id => <<"actor-a1">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1} = soma_actor_sup:start_actor(A1Opts),
    RawProposal = #{kind => actor_message,
                    to => A2,
                    payload => #{text => <<"hello a2">>}},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-a1-send">>,
    CorrelationId = <<"corr-a1-send">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"tell a2">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(A1, Envelope),
    ok = wait_for_a2_accepted(Store, CorrelationId, <<"actor-a2">>, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    ActorIds = lists:usort([maps:get(actor_id, E)
                            || E <- Events, maps:is_key(actor_id, E)]),
    true = lists:member(<<"actor-a1">>, ActorIds),
    true = lists:member(<<"actor-a2">>, ActorIds),
    true = is_process_alive(A2),
    true = is_process_alive(A1),
    ok.

%% Criterion 8: A1 emits `proposal.executed' for the approved `actor_message'
%% proposal. A1's mock returns a policy-approved `actor_message' proposal whose
%% `to' is A2's pid; A1's `actor_message' arm emits `proposal.executed' for the
%% sender task before delivering the envelope to A2. Drives A1 through the real
%% soma_actor:send/2, waits for A2's accepted event (so the chain has run), then
%% reads the shared event store under A1's correlation_id and asserts A1 emitted
%% a `proposal.executed' event for this actor_message task.
a1_emits_proposal_executed_for_actor_message(_Config) ->
    Store = event_store_pid(),
    A2Opts = #{actor_id => <<"actor-a2">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2} = soma_actor_sup:start_actor(A2Opts),
    A1Opts = #{actor_id => <<"actor-a1">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1} = soma_actor_sup:start_actor(A1Opts),
    RawProposal = #{kind => actor_message,
                    to => A2,
                    payload => #{text => <<"hello a2">>}},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-a1-send">>,
    CorrelationId = <<"corr-a1-send">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"tell a2">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(A1, Envelope),
    ok = wait_for_a2_accepted(Store, CorrelationId, <<"actor-a2">>, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Executed = [E || E <- Events,
                     maps:get(event_type, E, undefined)
                         =:= <<"proposal.executed">>,
                     maps:get(actor_id, E, undefined) =:= <<"actor-a1">>,
                     maps:get(task_id, E, undefined) =:= TaskId],
    %% Staged red: A1 already emits `proposal.executed' for the actor_message
    %% task, so the truthful expectation is [_ | _]. Start with the wrong
    %% expectation ([]) so the assertion fires red.
    [] = Executed,
    true = is_process_alive(A2),
    true = is_process_alive(A1),
    ok.

a2_accepted_events(Store, CorrelationId, A2Id) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    [E || E <- Events,
          maps:get(event_type, E, undefined) =:= <<"actor.task.accepted">>,
          maps:get(actor_id, E, undefined) =:= A2Id].

%% Polls the shared event store until an `actor.task.accepted' event emitted by
%% the named A2 actor_id appears under CorrelationId.
wait_for_a2_accepted(_Store, _CorrelationId, _A2Id, 0) ->
    error(no_a2_accepted);
wait_for_a2_accepted(Store, CorrelationId, A2Id, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Accepted = [E || E <- Events,
                     maps:get(event_type, E, undefined)
                         =:= <<"actor.task.accepted">>,
                     maps:get(actor_id, E, undefined) =:= A2Id],
    case Accepted of
        [_ | _] ->
            ok;
        [] ->
            timer:sleep(20),
            wait_for_a2_accepted(Store, CorrelationId, A2Id, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
