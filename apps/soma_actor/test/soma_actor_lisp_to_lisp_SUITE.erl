%% @doc Actor-to-actor Lisp proofs (L.2): one actor (A1) whose mock returns a
%% policy-approved `actor_message' proposal whose *body* is a Lisp `(msg ...)'
%% string carrying steps delivers it to a second actor (A2); A2 parses the Lisp
%% at its own `soma_actor:send/2' string clause (reusing the L.1 path) and runs
%% the steps. The proof compares the receiving actor's terminal task status with
%% the equivalent map-bodied `actor_message' carrying the same steps. Set up like
%% soma_actor_message_SUITE: boot the soma_runtime app (so the shared event store
%% and soma_run_sup are alive), start two actors through
%% soma_actor_sup:start_actor/1, and drive A1 through the real soma_actor:send/2
%% with a `proposal' llm directive -- the full decision-to-delivery chain, no
%% layer bypassed, mock LLM only.
-module(soma_actor_lisp_to_lisp_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([lisp_body_reaches_same_terminal_status_as_map/1]).
-export([lisp_body_produces_same_step_outputs_as_map/1]).
-export([by_correlation_spans_both_actors_for_lisp_body/1]).
-export([malformed_lisp_body_marks_task_failed/1]).
-export([actor_alive_and_accepts_after_malformed_body/1]).

all() ->
    [lisp_body_reaches_same_terminal_status_as_map,
     lisp_body_produces_same_step_outputs_as_map,
     by_correlation_spans_both_actors_for_lisp_body,
     malformed_lisp_body_marks_task_failed,
     actor_alive_and_accepts_after_malformed_body].

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

%% Criterion 1: an approved `actor_message' proposal whose body is a Lisp
%% `(msg ...)' string carrying steps drives the receiving actor's task to the same
%% terminal status as the equivalent map-bodied `actor_message' carrying the same
%% steps. Two A2 receivers (one per body form) each get exactly one delivery
%% driven through the real A1 decision-to-delivery chain (a `proposal' mock
%% directive whose `actor_message' proposal names that A2's pid as `to'). Each A2
%% receiver task is found by its `actor.task.accepted' event under A1's
%% correlation_id, then its terminal status is read from A2 and the two are
%% asserted equal -- and not stuck at `accepted', so the comparison proves a real
%% run ran on each.
lisp_body_reaches_same_terminal_status_as_map(_Config) ->
    Store = event_store_pid(),

    %% --- Lisp-bodied delivery: A1 -> A2L ---
    A2LOpts = #{actor_id => <<"actor-a2-lisp">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2L} = soma_actor_sup:start_actor(A2LOpts),
    A1LOpts = #{actor_id => <<"actor-a1-lisp">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1L} = soma_actor_sup:start_actor(A1LOpts),
    %% The proposal body is a Lisp `(msg ...)' string carrying one echo step.
    LispBody = <<"(msg (type chat) (payload \"hi\") "
                 "(steps (step (id s1) (tool echo) "
                 "(args (value \"hi\")))))">>,
    LispProposal = #{kind => actor_message, to => A2L, payload => LispBody},
    LispCorr = <<"corr-l2-lisp">>,
    LispEnvelope = #{type => <<"chat">>,
                    payload => #{text => <<"tell a2">>},
                    task_id => <<"task-l2-lisp">>,
                    correlation_id => LispCorr,
                    llm => #{directive => proposal, output => LispProposal}},
    {ok, <<"task-l2-lisp">>} = soma_actor:send(A1L, LispEnvelope),
    LispReceiverTask = wait_for_a2_task(Store, LispCorr, <<"actor-a2-lisp">>, 100),
    LispStatus = wait_for_terminal(A2L, LispReceiverTask, 100),

    %% --- Map-bodied delivery: A1 -> A2M, same steps ---
    A2MOpts = #{actor_id => <<"actor-a2-map">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2M} = soma_actor_sup:start_actor(A2MOpts),
    A1MOpts = #{actor_id => <<"actor-a1-map">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1M} = soma_actor_sup:start_actor(A1MOpts),
    %% The map body is the envelope the Lisp string parses into: same type,
    %% payload and one echo step.
    MapBody = #{type => chat,
                payload => <<"hi">>,
                steps => [#{id => s1, tool => echo,
                            args => #{value => <<"hi">>}}]},
    MapProposal = #{kind => actor_message, to => A2M, payload => MapBody},
    MapCorr = <<"corr-l2-map">>,
    MapEnvelope = #{type => <<"chat">>,
                   payload => #{text => <<"tell a2">>},
                   task_id => <<"task-l2-map">>,
                   correlation_id => MapCorr,
                   llm => #{directive => proposal, output => MapProposal}},
    {ok, <<"task-l2-map">>} = soma_actor:send(A1M, MapEnvelope),
    MapReceiverTask = wait_for_a2_task(Store, MapCorr, <<"actor-a2-map">>, 100),
    MapStatus = wait_for_terminal(A2M, MapReceiverTask, 100),

    %% The Lisp body and the equivalent map body drive their receivers to the same
    %% terminal status -- and both ran a step, so neither is stuck at `accepted'.
    completed = LispStatus,
    LispStatus = MapStatus,
    true = is_process_alive(A2L),
    true = is_process_alive(A2M),
    true = is_process_alive(A1L),
    true = is_process_alive(A1M),
    ok.

%% Criterion 2: the receiving actor's run for a Lisp-bodied `actor_message'
%% produces the same step outputs as the run for the equivalent map-bodied
%% `actor_message'. Both bodies carry one deterministic `echo' step over a fixed
%% value, so the two receiver runs' step outputs (read from each A2's
%% `get_task_result/2', which is the `run_completed' outputs map keyed by step id)
%% are directly comparable. Driven through the same real A1 decision-to-delivery
%% chain as Criterion 1 (a `proposal' mock directive), once per body form.
lisp_body_produces_same_step_outputs_as_map(_Config) ->
    Store = event_store_pid(),

    %% --- Lisp-bodied delivery: A1 -> A2L ---
    A2LOpts = #{actor_id => <<"actor-a2-lisp">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2L} = soma_actor_sup:start_actor(A2LOpts),
    A1LOpts = #{actor_id => <<"actor-a1-lisp">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1L} = soma_actor_sup:start_actor(A1LOpts),
    LispBody = <<"(msg (type chat) (payload \"hi\") "
                 "(steps (step (id s1) (tool echo) "
                 "(args (value \"hi\")))))">>,
    LispProposal = #{kind => actor_message, to => A2L, payload => LispBody},
    LispCorr = <<"corr-l2-out-lisp">>,
    LispEnvelope = #{type => <<"chat">>,
                    payload => #{text => <<"tell a2">>},
                    task_id => <<"task-l2-out-lisp">>,
                    correlation_id => LispCorr,
                    llm => #{directive => proposal, output => LispProposal}},
    {ok, <<"task-l2-out-lisp">>} = soma_actor:send(A1L, LispEnvelope),
    LispReceiverTask =
        wait_for_a2_task(Store, LispCorr, <<"actor-a2-lisp">>, 100),
    completed = wait_for_terminal(A2L, LispReceiverTask, 100),
    {ok, LispOutputs} = soma_actor:get_task_result(A2L, LispReceiverTask),

    %% --- Map-bodied delivery: A1 -> A2M, same steps ---
    A2MOpts = #{actor_id => <<"actor-a2-map">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2M} = soma_actor_sup:start_actor(A2MOpts),
    A1MOpts = #{actor_id => <<"actor-a1-map">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1M} = soma_actor_sup:start_actor(A1MOpts),
    MapBody = #{type => chat,
                payload => <<"hi">>,
                steps => [#{id => s1, tool => echo,
                            args => #{value => <<"hi">>}}]},
    MapProposal = #{kind => actor_message, to => A2M, payload => MapBody},
    MapCorr = <<"corr-l2-out-map">>,
    MapEnvelope = #{type => <<"chat">>,
                   payload => #{text => <<"tell a2">>},
                   task_id => <<"task-l2-out-map">>,
                   correlation_id => MapCorr,
                   llm => #{directive => proposal, output => MapProposal}},
    {ok, <<"task-l2-out-map">>} = soma_actor:send(A1M, MapEnvelope),
    MapReceiverTask =
        wait_for_a2_task(Store, MapCorr, <<"actor-a2-map">>, 100),
    completed = wait_for_terminal(A2M, MapReceiverTask, 100),
    {ok, MapOutputs} = soma_actor:get_task_result(A2M, MapReceiverTask),

    %% The Lisp body and the equivalent map body produce identical step outputs.
    LispOutputs = MapOutputs,
    true = is_process_alive(A2L),
    true = is_process_alive(A2M),
    ok.

%% Criterion 3: `soma_event_store:by_correlation/2' on the sender's
%% correlation_id returns both the sender's and the receiver's events for a
%% Lisp-bodied actor-to-actor message. A1's mock returns an approved
%% `actor_message' whose body is a Lisp `(msg ...)' string carrying one echo
%% step, delivered to A2; the sender appends its own correlation_id to the Lisp
%% source before delivery, so A2's parsed task lands under A1's id. A single
%% `by_correlation/2' read on A1's id is then asserted to carry events emitted by
%% both A1 (the sender's `actor.task.accepted') and A2 (the receiver's
%% `actor.task.accepted'), proving the chain spans both actors.
by_correlation_spans_both_actors_for_lisp_body(_Config) ->
    Store = event_store_pid(),
    A2Opts = #{actor_id => <<"actor-a2-corr">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2} = soma_actor_sup:start_actor(A2Opts),
    A1Opts = #{actor_id => <<"actor-a1-corr">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1} = soma_actor_sup:start_actor(A1Opts),
    LispBody = <<"(msg (type chat) (payload \"hi\") "
                 "(steps (step (id s1) (tool echo) "
                 "(args (value \"hi\")))))">>,
    LispProposal = #{kind => actor_message, to => A2, payload => LispBody},
    Corr = <<"corr-l2-span">>,
    Envelope = #{type => <<"chat">>,
                payload => #{text => <<"tell a2">>},
                task_id => <<"task-l2-span">>,
                correlation_id => Corr,
                llm => #{directive => proposal, output => LispProposal}},
    {ok, <<"task-l2-span">>} = soma_actor:send(A1, Envelope),
    %% Wait for the receiver task on A2 to land under A1's correlation_id and
    %% reach a terminal status, so both chains have been written to the store.
    ReceiverTask = wait_for_a2_task(Store, Corr, <<"actor-a2-corr">>, 100),
    completed = wait_for_terminal(A2, ReceiverTask, 100),

    %% One by_correlation/2 read on the sender's id returns events from both
    %% actors: the sender (A1) and the receiver (A2).
    Events = soma_event_store:by_correlation(Store, Corr),
    ActorIds = lists:usort([maps:get(actor_id, E)
                            || E <- Events, maps:is_key(actor_id, E)]),
    true = lists:member(<<"actor-a1-corr">>, ActorIds),
    true = lists:member(<<"actor-a2-corr">>, ActorIds),
    ok.

%% Criterion 4: a malformed Lisp body delivered as an approved `actor_message'
%% leaves a terminal `failed' task with no crash. The malformed body never creates
%% a receiver task -- the parse fails at the sender's `send/2' string clause
%% (`soma_lfe:compile/2' returns `{error, _}', so `send/2' returns `{error, _}')
%% before the receiver process is reached. So the task that lands in `failed' is
%% the sender's own `actor_message' task, recorded as data. The proof drives A1
%% through the real decision-to-delivery chain (a `proposal' mock directive whose
%% `actor_message' body is an unparseable Lisp string naming A2 as `to'), then
%% asserts the sender task is `failed' and both actor pids survive.
malformed_lisp_body_marks_task_failed(_Config) ->
    Store = event_store_pid(),
    A2Opts = #{actor_id => <<"actor-a2-bad">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2} = soma_actor_sup:start_actor(A2Opts),
    A1Opts = #{actor_id => <<"actor-a1-bad">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1} = soma_actor_sup:start_actor(A1Opts),
    %% An unparseable Lisp body: an unterminated `(msg ...)' form with no closing
    %% paren, so soma_lfe:compile/2 fails to parse it.
    BadBody = <<"(msg (type chat) (payload \"hi\"">>,
    BadProposal = #{kind => actor_message, to => A2, payload => BadBody},
    Corr = <<"corr-l2-bad">>,
    Envelope = #{type => <<"chat">>,
                payload => #{text => <<"tell a2">>},
                task_id => <<"task-l2-bad">>,
                correlation_id => Corr,
                llm => #{directive => proposal, output => BadProposal}},
    {ok, <<"task-l2-bad">>} = soma_actor:send(A1, Envelope),

    %% The sender's `actor_message' task fails as data: it leaves `accepted' for
    %% the terminal `failed' status. No receiver task is ever created.
    failed = wait_for_terminal(A1, <<"task-l2-bad">>, 100),

    %% Both actor pids survive -- the malformed body was recorded as data, not a
    %% crash, and the receiver was never reached.
    true = is_process_alive(A1),
    true = is_process_alive(A2),
    ok.

%% Criterion 5: after a malformed Lisp body fails a sender task, the receiving
%% actor pid is still alive and accepts a following valid message. The malformed
%% body fails A1's first `actor_message' task as data (its parse fails at the
%% sender's `send/2' before the receiver process is reached, so A2 is never
%% touched); then a second, valid map-bodied `actor_message' is delivered to the
%% *same* A2 through the real A1 decision-to-delivery chain. The proof asserts A2
%% is alive between the two deliveries and that the following valid message
%% reaches a terminal status on A2.
actor_alive_and_accepts_after_malformed_body(_Config) ->
    Store = event_store_pid(),
    A2Opts = #{actor_id => <<"actor-a2-after">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A2} = soma_actor_sup:start_actor(A2Opts),
    A1Opts = #{actor_id => <<"actor-a1-after">>,
               model_config => #{},
               tool_policy => #{},
               event_store => Store},
    {ok, A1} = soma_actor_sup:start_actor(A1Opts),

    %% --- First delivery: a malformed Lisp body fails A1's task ---
    BadBody = <<"(msg (type chat) (payload \"hi\"">>,
    BadProposal = #{kind => actor_message, to => A2, payload => BadBody},
    BadCorr = <<"corr-l2-after-bad">>,
    BadEnvelope = #{type => <<"chat">>,
                   payload => #{text => <<"tell a2">>},
                   task_id => <<"task-l2-after-bad">>,
                   correlation_id => BadCorr,
                   llm => #{directive => proposal, output => BadProposal}},
    {ok, <<"task-l2-after-bad">>} = soma_actor:send(A1, BadEnvelope),
    failed = wait_for_terminal(A1, <<"task-l2-after-bad">>, 100),

    %% Between deliveries: the receiving actor pid is still alive -- the malformed
    %% body never reached it.
    true = is_process_alive(A2),

    %% --- Second delivery: a valid map-bodied message to the same A2 ---
    MapBody = #{type => chat,
                payload => <<"hi">>,
                steps => [#{id => s1, tool => echo,
                            args => #{value => <<"hi">>}}]},
    MapProposal = #{kind => actor_message, to => A2, payload => MapBody},
    GoodCorr = <<"corr-l2-after-good">>,
    GoodEnvelope = #{type => <<"chat">>,
                    payload => #{text => <<"tell a2">>},
                    task_id => <<"task-l2-after-good">>,
                    correlation_id => GoodCorr,
                    llm => #{directive => proposal, output => MapProposal}},
    {ok, <<"task-l2-after-good">>} = soma_actor:send(A1, GoodEnvelope),
    ReceiverTask = wait_for_a2_task(Store, GoodCorr, <<"actor-a2-after">>, 100),
    completed = wait_for_terminal(A2, ReceiverTask, 100),

    %% Both actors survive the whole sequence.
    true = is_process_alive(A2),
    true = is_process_alive(A1),
    ok.

%% Polls the shared store until an `actor.task.accepted' event emitted by the
%% named A2 actor_id appears under CorrelationId, returning that task_id -- the
%% receiver task the delivery created on A2.
wait_for_a2_task(_Store, _CorrelationId, _A2Id, 0) ->
    error(no_a2_task);
wait_for_a2_task(Store, CorrelationId, A2Id, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Accepted = [E || E <- Events,
                     maps:get(event_type, E, undefined)
                         =:= <<"actor.task.accepted">>,
                     maps:get(actor_id, E, undefined) =:= A2Id],
    case Accepted of
        [E | _] ->
            maps:get(task_id, E);
        [] ->
            timer:sleep(20),
            wait_for_a2_task(Store, CorrelationId, A2Id, N - 1)
    end.

%% Polls A2's task status until it leaves `accepted' for a terminal status,
%% returning that status.
wait_for_terminal(_ActorPid, _TaskId, 0) ->
    error(no_terminal_status);
wait_for_terminal(ActorPid, TaskId, N) ->
    case maps:get(status, soma_actor:get_task_status(ActorPid, TaskId)) of
        accepted ->
            timer:sleep(20),
            wait_for_terminal(ActorPid, TaskId, N - 1);
        Status ->
            Status
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
