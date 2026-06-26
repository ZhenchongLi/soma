%% @doc L.5 actor-side proofs that a malformed Lisp proposal is handed back to the
%% LLM for a bounded, re-validated repair. The repaired output re-enters the full
%% decision chain (soma_actor:send/2 -> idle/3 -> soma_llm_call `proposal'
%% directive -> proposal_result/2 `{invalid_proposal, _}' -> repair start_llm_call
%% -> second llm_result -> proposal_result/2 `{proposal, _}' -> soma_policy:check/2
%% -> terminal), never a side-path parse-and-inject. Set up like
%% soma_actor_lisp_proposal_SUITE: boot soma_runtime, start an actor through
%% soma_actor_sup:start_actor/1 with a `tool_policy', and drive it through the real
%% soma_actor:send/2 with an `llm' envelope carrying a `proposal' directive whose
%% `output' is a malformed Lisp string and whose `repair_output' is the s-expr the
%% repair call should return. Mock LLM only -- no real provider, no network socket.
-module(soma_actor_lisp_repair_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([repaired_reply_reaches_same_terminal_result_as_valid_reply/1]).
-export([successful_repair_emits_proposal_repaired_with_ids/1]).
-export([repaired_run_steps_outside_allowlist_is_rejected/1]).

all() ->
    [repaired_reply_reaches_same_terminal_result_as_valid_reply,
     successful_repair_emits_proposal_repaired_with_ids,
     repaired_run_steps_outside_allowlist_is_rejected].

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

%% Criterion 1: a malformed Lisp proposal whose repair call returns a valid
%% `(reply ...)' drives the task to the same terminal result -- `completed', with
%% the normalized reply proposal as the task result -- as a directly-valid Lisp
%% reply proposal. The malformed proposal's `llm' map carries the s-expr the repair
%% call should return under `repair_output'; the actor (repair on by default) starts
%% a repair call whose output is that valid `(reply ...)', which re-enters the full
%% pipeline and completes. The directly-valid arm sends `(reply (text "hi"))'
%% straight through. Both get_task_result/2 return the same normalized
%% `#{kind => reply, text => <<"hi">>}'.
repaired_reply_reaches_same_terminal_result_as_valid_reply(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-repair">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),

    %% The malformed Lisp proposal the mock LLM first emits (an unterminated form
    %% soma_lfe:compile/2 cannot parse), paired with the valid s-expr the repair
    %% call should return under `repair_output'.
    BadProposal = <<"(reply (text \"hi\"">>,
    RepairedProposal = <<"(reply (text \"hi\"))">>,
    RepairLlm = #{directive => proposal,
                  output => BadProposal,
                  repair_output => RepairedProposal},
    RepairTaskId = <<"task-lisp-repair">>,
    RepairEnvelope = #{type => <<"chat">>,
                      payload => #{text => <<"answer me">>},
                      task_id => RepairTaskId,
                      correlation_id => <<"corr-lisp-repair">>,
                      llm => RepairLlm},
    {ok, RepairTaskId} = soma_actor:send(ActorPid, RepairEnvelope),
    ok = wait_for_status(ActorPid, RepairTaskId, completed, 100),
    {ok, RepairResult} = soma_actor:get_task_result(ActorPid, RepairTaskId),

    %% The directly-valid Lisp reply proposal through the same actor.
    ValidProposal = <<"(reply (text \"hi\"))">>,
    ValidLlm = #{directive => proposal, output => ValidProposal},
    ValidTaskId = <<"task-lisp-valid">>,
    ValidEnvelope = #{type => <<"chat">>,
                     payload => #{text => <<"answer me">>},
                     task_id => ValidTaskId,
                     correlation_id => <<"corr-lisp-valid">>,
                     llm => ValidLlm},
    {ok, ValidTaskId} = soma_actor:send(ActorPid, ValidEnvelope),
    ok = wait_for_status(ActorPid, ValidTaskId, completed, 100),
    {ok, ValidResult} = soma_actor:get_task_result(ActorPid, ValidTaskId),

    %% Same terminal result: the repaired proposal normalizes to the same reply
    %% proposal the directly-valid one does.
    #{kind := reply, text := <<"hi">>} = RepairResult,
    RepairResult = ValidResult,
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 2: when a malformed proposal is repaired and the repaired form
%% re-parses successfully, the actor emits exactly one `proposal.repaired' event
%% carrying the task's `task_id' and `correlation_id'. The malformed proposal's
%% `llm' map stages a valid `(reply ...)' under `repair_output'; the repair call
%% returns it, it re-parses, and at that re-parse point `proposal.repaired' fires.
%% The event is read back through soma_event_store:by_correlation/2 for the task's
%% correlation, and is distinct from `proposal.created'.
successful_repair_emits_proposal_repaired_with_ids(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-repair-2">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),

    BadProposal = <<"(reply (text \"hi\"">>,
    RepairedProposal = <<"(reply (text \"hi\"))">>,
    RepairLlm = #{directive => proposal,
                  output => BadProposal,
                  repair_output => RepairedProposal},
    TaskId = <<"task-lisp-repaired-event">>,
    CorrelationId = <<"corr-lisp-repaired-event">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"answer me">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => RepairLlm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),

    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Repaired = [E || E <- Events,
                     maps:get(event_type, E, undefined) =:= <<"proposal.repaired">>],
    [RepairedEvent] = Repaired,
    TaskId = maps:get(task_id, RepairedEvent),
    CorrelationId = maps:get(correlation_id, RepairedEvent),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 3: a repaired `run_steps' proposal whose tool is outside the actor's
%% `allowed_tools' allowlist reaches terminal `rejected' and emits
%% `proposal.rejected'. The repaired form re-enters the full pipeline -- the policy
%% gate runs on the repaired proposal, so repair does not bypass it. The malformed
%% proposal's `llm' map stages, under `repair_output', a valid `(run-steps ...)'
%% whose single step's tool (`file_write') is NOT in the actor's allowlist (`echo'
%% only). The repair call returns it, it re-parses and normalizes to a `run_steps'
%% proposal, soma_policy:check/2 rejects it, and the task lands `rejected' with a
%% `proposal.rejected' event read back through soma_event_store:by_correlation/2.
repaired_run_steps_outside_allowlist_is_rejected(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-repair-3">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),

    %% Malformed (unterminated) run-steps form; its repair returns a valid
    %% run-steps proposal whose tool `file_write' is outside the `[echo]' allowlist.
    BadProposal = <<"(run-steps (step (id s1) (tool file_write) (args (value \"a\"">>,
    RepairedProposal =
        <<"(run-steps (step (id s1) (tool file_write) (args (value \"a\"))))">>,
    RepairLlm = #{directive => proposal,
                  output => BadProposal,
                  repair_output => RepairedProposal},
    TaskId = <<"task-lisp-repair-rejected">>,
    CorrelationId = <<"corr-lisp-repair-rejected">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do a thing">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => RepairLlm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, rejected, 100),

    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Rejected = [E || E <- Events,
                     maps:get(event_type, E, undefined) =:= <<"proposal.rejected">>],
    [_RejectedEvent] = Rejected,
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
