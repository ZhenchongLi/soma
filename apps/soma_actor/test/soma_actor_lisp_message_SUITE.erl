%% @doc Lisp-envelope proofs for soma_actor (L.1). A Lisp `(msg ...)' string
%% handed to soma_actor:send/2 is parsed at the client-side wrapper through
%% soma_lfe:compile/2 into the exact map envelope the actor already takes, then
%% runs through the unchanged map path. Set up like soma_actor_message_SUITE:
%% boot the soma_runtime app (so the shared event store and soma_run_sup are
%% alive) and start an actor through soma_actor_sup:start_actor/1, driving it
%% through the real soma_actor:send/2 entry point -- no layer bypassed.
-module(soma_actor_lisp_message_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_lisp_send_matches_map_send_outputs/1]).
-export([test_lisp_send_correlation_chain_matches_map/1]).
-export([test_malformed_lisp_send_actor_survives/1]).
-export([test_lisp_ask_matches_map_ask_result/1]).
-export([test_map_send_path_untouched/1]).

all() ->
    [test_lisp_send_matches_map_send_outputs,
     test_lisp_send_correlation_chain_matches_map,
     test_malformed_lisp_send_actor_survives,
     test_lisp_ask_matches_map_ask_result,
     test_map_send_path_untouched].

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

%% Criterion 5: soma_actor:send/2 called with a valid Lisp `(msg ...)' string
%% produces the same run outputs as send/2 called with the equivalent map
%% envelope. The `(msg ...)' string carries one echo step; the equivalent map
%% envelope carries the same step list (and the same type/payload the parser
%% produces). Both drive the real soma_actor:send/2 on a single actor; each task
%% runs its own soma_run to completion. The test reads each task's outputs via
%% get_task_result/2 (polling until ready) and asserts the two are equal.
test_lisp_send_matches_map_send_outputs(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-send">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),

    %% Lisp path: a `(msg ...)' string with one echo step.
    LispSource = <<"(msg (type chat) (payload \"hi\") "
                   "(steps (step (id s1) (tool echo) "
                   "(args (value \"hi\")))))">>,
    {ok, LispTaskId} = soma_actor:send(Pid, LispSource),
    {ok, LispResult} = wait_for_task_result(Pid, LispTaskId, 100),

    %% Map path: the equivalent map envelope the parser produces for that string.
    MapEnvelope = #{type => chat,
                    payload => <<"hi">>,
                    steps => [#{id => s1,
                                tool => echo,
                                args => #{value => <<"hi">>}}]},
    {ok, MapTaskId} = soma_actor:send(Pid, MapEnvelope),
    {ok, MapResult} = wait_for_task_result(Pid, MapTaskId, 100),

    %% The same work through both entry forms yields equal run outputs.
    LispResult = MapResult,
    true = is_process_alive(Pid),
    ok.

%% Criterion 6: the correlation chain a Lisp `(msg ...)' send/2 leaves in the
%% event store -- read back through soma_event_store:by_correlation/2 -- matches
%% the chain the equivalent map send/2 leaves. Each path is driven under its own
%% known correlation id (carried in the envelope: `(correlation-id "...")' on the
%% Lisp side, `correlation_id => ...' on the map side) so the two buckets are
%% disjoint, then the event_type sequences pulled from each bucket are compared.
test_lisp_send_correlation_chain_matches_map(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-corr">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),

    LispCorr = <<"corr-lisp-1">>,
    MapCorr = <<"corr-map-1">>,

    %% Lisp path: a `(msg ...)' string with one echo step under LispCorr.
    LispSource = <<"(msg (type chat) (payload \"hi\") "
                   "(correlation-id \"corr-lisp-1\") "
                   "(steps (step (id s1) (tool echo) "
                   "(args (value \"hi\")))))">>,
    {ok, LispTaskId} = soma_actor:send(Pid, LispSource),
    {ok, _} = wait_for_task_result(Pid, LispTaskId, 100),

    %% Map path: the equivalent map envelope under MapCorr.
    MapEnvelope = #{type => chat,
                    payload => <<"hi">>,
                    correlation_id => MapCorr,
                    steps => [#{id => s1,
                                tool => echo,
                                args => #{value => <<"hi">>}}]},
    {ok, MapTaskId} = soma_actor:send(Pid, MapEnvelope),
    {ok, _} = wait_for_task_result(Pid, MapTaskId, 100),

    LispChain = correlation_event_types(Store, LispCorr),
    MapChain = correlation_event_types(Store, MapCorr),

    %% Both forms drive the same work, so the correlation chains match in shape.
    LispChain = MapChain,
    true = is_process_alive(Pid),
    ok.

%% Criterion 7: soma_actor:send/2 called with a malformed Lisp `(msg ...)'
%% string returns `{error, _}', and the same actor process stays alive and
%% accepts a following message. The malformed string is rejected at the wrapper
%% by soma_lfe:compile/2 before the actor is ever called, so the actor never
%% sees it; the following valid map send proves the process is still alive and
%% serving by running a step list to completion on the same pid.
test_malformed_lisp_send_actor_survives(_Config) ->
    Opts = #{actor_id => <<"actor-lisp-malformed">>,
             model_config => #{},
             tool_policy => #{},
             event_store => event_store_pid()},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),

    %% A malformed Lisp string: unbalanced parens, so the reader/parser rejects
    %% it. The wrapper returns the diagnostics without calling the actor.
    Malformed = <<"(msg (type chat) (payload \"hi\"">>,
    {error, _} = soma_actor:send(Pid, Malformed),
    true = is_process_alive(Pid),

    %% The same actor accepts and completes a following valid map envelope.
    MapEnvelope = #{type => chat,
                    payload => <<"hi">>,
                    steps => [#{id => s1,
                                tool => echo,
                                args => #{value => <<"hi">>}}]},
    {ok, TaskId} = soma_actor:send(Pid, MapEnvelope),
    {ok, _Result} = wait_for_task_result(Pid, TaskId, 100),
    true = is_process_alive(Pid),
    ok.

%% Criterion 8: soma_actor:ask/3 called with a valid Lisp `(msg ...)' string
%% returns the same result as ask/3 called with the equivalent map envelope. The
%% `(msg ...)' string is parsed at the wrapper through soma_lfe:compile/2 into the
%% exact map envelope the map path takes, then runs through the unchanged
%% {ask, Envelope} path: ask/3 blocks inside its gen_statem:call until the run
%% completes and returns {ok, Result}. Both forms carry one echo step on a single
%% actor; the two {ok, Result} replies are asserted equal.
test_lisp_ask_matches_map_ask_result(_Config) ->
    Opts = #{actor_id => <<"actor-lisp-ask">>,
             model_config => #{},
             tool_policy => #{},
             event_store => event_store_pid()},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),

    %% Lisp path: a `(msg ...)' string with one echo step, submitted via ask/3.
    LispSource = <<"(msg (type chat) (payload \"hi\") "
                   "(steps (step (id s1) (tool echo) "
                   "(args (value \"hi\")))))">>,
    {ok, LispResult} = soma_actor:ask(Pid, LispSource, 2000),

    %% Map path: the equivalent map envelope the parser produces for that string.
    MapEnvelope = #{type => chat,
                    payload => <<"hi">>,
                    steps => [#{id => s1,
                                tool => echo,
                                args => #{value => <<"hi">>}}]},
    {ok, MapResult} = soma_actor:ask(Pid, MapEnvelope, 2000),

    %% The same work through both ask/3 entry forms yields equal run results.
    LispResult = MapResult,
    true = is_process_alive(Pid),
    ok.

%% Criterion 9: soma_actor:send/2 called with a map envelope still runs
%% unchanged -- the existing map path is untouched by the Lisp boundary added
%% for the binary/string argument. A map argument never goes through
%% soma_lfe:compile/2; it drives the same {send, Envelope} path it does today and
%% runs to `actor.task.completed'. The test sends a plain map envelope under a
%% known correlation id, waits for the task result, then asserts the task status
%% reached `completed' and an `actor.task.completed' event landed in the store
%% for that correlation chain.
test_map_send_path_untouched(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-map-untouched">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),

    Corr = <<"corr-map-untouched-1">>,
    MapEnvelope = #{type => chat,
                    payload => <<"hi">>,
                    correlation_id => Corr,
                    steps => [#{id => s1,
                                tool => echo,
                                args => #{value => <<"hi">>}}]},
    {ok, TaskId} = soma_actor:send(Pid, MapEnvelope),
    {ok, _Result} = wait_for_task_result(Pid, TaskId, 100),

    %% The map path runs to completion: status `completed' and the
    %% `actor.task.completed' event is in the correlation chain.
    #{status := completed} = soma_actor:get_task_status(Pid, TaskId),
    Chain = correlation_event_types(Store, Corr),
    true = lists:member(<<"actor.task.completed">>, Chain),
    true = is_process_alive(Pid),
    ok.

%% The event_type values from by_correlation/2, in store order.
correlation_event_types(Store, CorrelationId) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    [maps:get(event_type, E) || E <- Events].

%% Polls get_task_result/2 until the task has completed and returns {ok, Result}.
wait_for_task_result(_Pid, _TaskId, 0) ->
    error(no_task_result);
wait_for_task_result(Pid, TaskId, N) ->
    case soma_actor:get_task_result(Pid, TaskId) of
        {ok, Result} ->
            {ok, Result};
        _ ->
            timer:sleep(20),
            wait_for_task_result(Pid, TaskId, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
