%% @doc L.3 actor-side proofs that a mock LLM emitting a Lisp s-expr proposal
%% string drives the full decision chain (soma_actor:send/2 -> idle/3 ->
%% soma_llm_call `proposal' directive -> proposal_result/1 -> soma_lfe:compile/2
%% -> soma_proposal:normalize/1 -> soma_policy:check/2 -> terminal) exactly as the
%% equivalent raw-map proposal does. Set up like soma_proposal_exec_SUITE: boot
%% soma_runtime, start an actor through soma_actor_sup:start_actor/1 with a
%% `tool_policy', and drive it through the real soma_actor:send/2 with an `llm'
%% envelope carrying a `proposal' directive whose `output' is a Lisp string. Mock
%% LLM only -- no real provider, no network socket.
-module(soma_actor_lisp_proposal_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([lisp_reply_reaches_same_terminal_result_as_map_reply/1]).
-export([lisp_run_steps_emits_proposal_executed_and_runs/1]).

all() ->
    [lisp_reply_reaches_same_terminal_result_as_map_reply,
     lisp_run_steps_emits_proposal_executed_and_runs].

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

%% Criterion 4: a mock LLM returning a Lisp `(reply (text ...))' proposal string
%% drives the task to the same terminal result as the equivalent raw-map `reply'
%% proposal. Runs both through the real soma_actor:send/2 `proposal' directive --
%% one with a Lisp string `output', one with the equivalent raw map -- waits for
%% each task to reach `completed', and asserts both get_task_result/2 return the
%% same normalized proposal `#{kind => reply, text => <<"hi">>}'.
lisp_reply_reaches_same_terminal_result_as_map_reply(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-reply">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),

    %% The Lisp s-expr proposal string the mock LLM emits.
    LispProposal = <<"(reply (text \"hi\"))">>,
    LispLlm = #{directive => proposal, output => LispProposal},
    LispTaskId = <<"task-lisp-reply">>,
    LispEnvelope = #{type => <<"chat">>,
                     payload => #{text => <<"answer me">>},
                     task_id => LispTaskId,
                     correlation_id => <<"corr-lisp-reply">>,
                     llm => LispLlm},
    {ok, LispTaskId} = soma_actor:send(ActorPid, LispEnvelope),
    ok = wait_for_status(ActorPid, LispTaskId, completed, 100),
    {ok, LispResult} = soma_actor:get_task_result(ActorPid, LispTaskId),

    %% The equivalent raw-map reply proposal through the same actor.
    MapProposal = #{kind => reply, text => <<"hi">>},
    MapLlm = #{directive => proposal, output => MapProposal},
    MapTaskId = <<"task-map-reply">>,
    MapEnvelope = #{type => <<"chat">>,
                    payload => #{text => <<"answer me">>},
                    task_id => MapTaskId,
                    correlation_id => <<"corr-map-reply">>,
                    llm => MapLlm},
    {ok, MapTaskId} = soma_actor:send(ActorPid, MapEnvelope),
    ok = wait_for_status(ActorPid, MapTaskId, completed, 100),
    {ok, MapResult} = soma_actor:get_task_result(ActorPid, MapTaskId),

    %% Same terminal result: the Lisp proposal normalizes to the same reply
    %% proposal the raw map does.
    #{kind := reply, text := <<"hi">>} = LispResult,
    LispResult = MapResult,
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 5: a mock LLM returning an approved Lisp `(run-steps ...)' proposal
%% string emits `proposal.executed' and the run runs, the same as the equivalent
%% raw-map `run_steps' proposal. Drives the Lisp string through the real
%% soma_actor:send/2 `proposal' directive (every step tool allowed), waits for the
%% task to reach `completed', reads the trail through by_correlation/2 and asserts
%% a `proposal.executed' and a `run.completed' event appear, and that
%% get_task_result/2 returns the same step outputs the equivalent raw-map proposal
%% would (echo of `s1' args), proving the Lisp proposal ran identically.
lisp_run_steps_emits_proposal_executed_and_runs(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-run-steps">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),

    %% The Lisp s-expr run-steps proposal string the mock LLM emits. Its single
    %% echo step is the Lisp equivalent of the raw-map run_steps proposal in
    %% soma_proposal_exec_SUITE.
    LispProposal = <<"(run-steps (step (id s1) (tool echo) (args (value \"a\"))))">>,
    Llm = #{directive => proposal, output => LispProposal},
    TaskId = <<"task-lisp-run-steps">>,
    CorrelationId = <<"corr-lisp-run-steps">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"do it">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),

    %% The approved Lisp run_steps proposal emitted `proposal.executed' and the
    %% run ran to `run.completed', the same trail the raw-map proposal produces.
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E, undefined) || E <- Events],
    true = lists:member(<<"proposal.executed">>, Types),
    true = lists:member(<<"run.completed">>, Types),

    %% Same terminal result: the single echo step s1 echoes its args unchanged,
    %% keyed by the step id, identical to the raw-map run_steps proposal.
    {ok, Outputs} = soma_actor:get_task_result(ActorPid, TaskId),
    #{<<"s1">> := #{value := <<"a">>}} = Outputs,
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
