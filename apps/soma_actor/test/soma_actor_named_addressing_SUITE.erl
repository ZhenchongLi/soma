%% @doc Stable-name addressing proofs (#183, criteria 5-11). These cover the
%% multi-agent name-addressing behaviours that emerge from the registry +
%% name-resolving send/2 + name-accepting actor_message normalize, which the
%% per-criterion TDD harness could not generate failing tests for (each was
%% already satisfied by the lookup / send / normalize work). Setup mirrors
%% soma_actor_message_SUITE: boot soma_runtime (shared store + soma_run_sup),
%% start soma_actor_sup (which owns the registry), drive actors through the real
%% soma_actor entry points -- no layer bypassed.
-module(soma_actor_named_addressing_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([actor_message_stable_name_delivers_task_after_approval/1]).
-export([restart_replaces_registry_entry/1]).
-export([unknown_name_lookup_and_send_not_found_caller_alive/1]).
-export([unknown_name_actor_message_sender_failed_and_alive/1]).

all() ->
    [actor_message_stable_name_delivers_task_after_approval,
     restart_replaces_registry_entry,
     unknown_name_lookup_and_send_not_found_caller_alive,
     unknown_name_actor_message_sender_failed_and_alive].

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
%% whose `to' is A2's *stable name* (a binary), not a pid. A1's delivery resolves
%% that name through send/2's registry lookup and delivers to A2, which accepts a
%% task under A1's correlation_id.
actor_message_stable_name_delivers_task_after_approval(_Config) ->
    Store = event_store_pid(),
    {ok, _A2} = start_named_actor(<<"actor-a2">>, <<"a2">>, Store),
    {ok, A1} = start_named_actor(<<"actor-a1">>, <<"a1">>, Store),
    RawProposal = #{kind => actor_message,
                    to => <<"a2">>,
                    payload => #{text => <<"hello a2">>}},
    CorrelationId = <<"corr-named-deliver">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"tell a2">>},
                 task_id => <<"task-a1-named">>,
                 correlation_id => CorrelationId,
                 llm => #{directive => proposal, output => RawProposal}},
    {ok, <<"task-a1-named">>} = soma_actor:send(A1, Envelope),
    ok = wait_for_accepted(Store, CorrelationId, <<"actor-a2">>, 100),
    ok.

%% Criterion 6: restarting a named actor under the same stable name replaces the
%% registry entry with the new pid. Start under <<"svc">>, kill it, start a fresh
%% actor under the same name, and assert the lookup now resolves to the new pid.
restart_replaces_registry_entry(_Config) ->
    Store = event_store_pid(),
    {ok, Old} = start_named_actor(<<"actor-svc-1">>, <<"svc">>, Store),
    {ok, Old} = wait_for_lookup_pid(<<"svc">>, Old, 50),
    MRef = monitor(process, Old),
    exit(Old, kill),
    receive {'DOWN', MRef, process, Old, _} -> ok after 2000 -> ct:fail(old_not_down) end,
    {ok, New} = start_named_actor(<<"actor-svc-2">>, <<"svc">>, Store),
    true = New =/= Old,
    {ok, New} = wait_for_lookup_pid(<<"svc">>, New, 50),
    true = is_process_alive(New),
    ok.

%% Criteria 7, 8, 9: an unknown stable name resolves to {error, not_found} both
%% from the registry directly and through send/2, and the calling process is not
%% taken down by the failed send (a subsequent known-name send still works).
unknown_name_lookup_and_send_not_found_caller_alive(_Config) ->
    Store = event_store_pid(),
    %% Criterion 7: direct lookup of an unknown name.
    {error, not_found} = soma_actor_registry:lookup(<<"ghost">>),
    %% Criterion 8: send to an unknown name.
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"anyone?">>},
                 steps => [#{id => s1, tool => echo,
                             args => #{value => <<"x">>}}]},
    {error, not_found} = soma_actor:send(<<"ghost">>, Envelope),
    %% Criterion 9: the caller survived -- it can still drive a known actor.
    true = is_process_alive(self()),
    {ok, A} = start_named_actor(<<"actor-live">>, <<"live">>, Store),
    Reply = soma_actor:ask(A, Envelope, 5000),
    {ok, _} = Reply,
    ok.

%% Criteria 10, 11: an `actor_message' proposal naming an unknown stable name
%% leaves the sender task `failed' after approval (the delivery resolves to
%% not_found), and the sender actor stays alive.
unknown_name_actor_message_sender_failed_and_alive(_Config) ->
    Store = event_store_pid(),
    {ok, A1} = start_named_actor(<<"actor-sender">>, <<"sender">>, Store),
    RawProposal = #{kind => actor_message,
                    to => <<"ghost">>,
                    payload => #{text => <<"hello ghost">>}},
    TaskId = <<"task-sender-unknown">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"tell ghost">>},
                 task_id => TaskId,
                 correlation_id => <<"corr-sender-unknown">>,
                 llm => #{directive => proposal, output => RawProposal}},
    {ok, TaskId} = soma_actor:send(A1, Envelope),
    ok = wait_for_task_failed(A1, TaskId, 100),
    true = is_process_alive(A1),
    ok.

%%% Helpers

start_named_actor(ActorId, StableName, Store) ->
    soma_actor_sup:start_actor(#{actor_id => ActorId,
                                 stable_name => StableName,
                                 model_config => #{},
                                 tool_policy => #{},
                                 event_store => Store}).

wait_for_lookup_pid(_Name, _Want, 0) ->
    {error, lookup_timeout};
wait_for_lookup_pid(Name, Want, N) ->
    case soma_actor_registry:lookup(Name) of
        {ok, Want} -> {ok, Want};
        _ -> timer:sleep(20), wait_for_lookup_pid(Name, Want, N - 1)
    end.

wait_for_accepted(_Store, _CorrelationId, _ActorId, 0) ->
    error(no_accepted);
wait_for_accepted(Store, CorrelationId, ActorId, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Accepted = [E || E <- Events,
                     maps:get(event_type, E, undefined)
                         =:= <<"actor.task.accepted">>,
                     maps:get(actor_id, E, undefined) =:= ActorId],
    case Accepted of
        [_ | _] -> ok;
        [] -> timer:sleep(20),
              wait_for_accepted(Store, CorrelationId, ActorId, N - 1)
    end.

wait_for_task_failed(_A1, _TaskId, 0) ->
    error(no_task_failed);
wait_for_task_failed(A1, TaskId, N) ->
    case soma_actor:get_task_status(A1, TaskId) of
        #{status := failed} -> ok;
        _ -> timer:sleep(20), wait_for_task_failed(A1, TaskId, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
