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

all() ->
    [reply_proposal_stored_as_task_result,
     reply_proposal_emits_proposal_created_with_correlation_id].

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
