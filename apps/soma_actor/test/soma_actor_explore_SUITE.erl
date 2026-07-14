%% @doc AS.3 actor exploration-loop proofs. Provider calls use the existing
%% fixed-response seam, so the suite exercises the real actor/worker/provider
%% path without opening a network socket.
-module(soma_actor_explore_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([explore_mode_provider_text_is_parsed_as_round_reply/1]).
-export([reader_explore_run_and_tool_worker_are_distinct_children/1]).
-export([reader_then_terminal_run_steps_carries_observation_and_outputs/1]).

all() ->
    [explore_mode_provider_text_is_parsed_as_round_reply,
     reader_explore_run_and_tool_worker_are_distinct_children,
     reader_then_terminal_run_steps_carries_observation_and_outputs].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup}, {started_apps, Started} | Config].

end_per_testcase(_TestCase, Config) ->
    case ?config(sup, Config) of
        undefined ->
            ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    application:stop(soma_runtime),
    ok.

explore_mode_provider_text_is_parsed_as_round_reply(_Config) ->
    Store = event_store_pid(),
    Source =
        <<"(explore (step (id inspect) (tool file_read) "
          "(args (path \"input.txt\"))))">>,
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Source}}]})),
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response => {200, Body}},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-round-reply">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [file_read]},
            event_store => Store}),
    TaskId = <<"task-explore-round-reply">>,
    CorrelationId = <<"corr-explore-round-reply">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"inspect input.txt">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_event(Store, CorrelationId, <<"llm.succeeded">>, 100),

    {idle, Data} = sys:get_state(ActorPid),
    Tasks = element(6, Data),
    Task = maps:get(TaskId, Tasks),
    ExpectedRoundReply =
        #{kind => explore,
          steps =>
              [#{id => inspect,
                 tool => file_read,
                 args => #{path => <<"input.txt">>}}]},
    ok = assert_equal(ExpectedRoundReply,
                      maps:get(explore_round_reply, Task, undefined)),
    ok = assert_equal(running, maps:get(status, Task)),
    ok = assert_equal(not_ready,
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

reader_explore_run_and_tool_worker_are_distinct_children(_Config) ->
    Store = event_store_pid(),
    Source =
        <<"(explore (step (id wait) (tool sleep) "
          "(args (ms 5000)) (timeout_ms 10000)))">>,
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Source}}]})),
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response => {200, Body}},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-process-boundaries">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [sleep]},
            event_store => Store}),
    TaskId = <<"task-explore-process-boundaries">>,
    CorrelationId = <<"corr-explore-process-boundaries">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"wait while inspecting">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_event_map(Store, CorrelationId,
                                 <<"tool.started">>, 100),
    ok = assert_equal(true, is_map(Started)),
    RunId = maps:get(run_id, Started),
    WorkerPid = maps:get(tool_call_pid, Started),
    {idle, Data} = sys:get_state(ActorPid),
    Tasks = element(6, Data),
    Task = maps:get(TaskId, Tasks),
    RunPid = maps:get(run_pid, Task),
    Runs = element(7, Data),
    RunContext = maps:get(RunId, Runs),
    RunChildren = [Pid || {_Id, Pid, _Type, _Mods} <-
                              supervisor:which_children(soma_run_sup),
                          is_pid(Pid)],

    ok = assert_equal(true, lists:member(RunPid, RunChildren)),
    ok = assert_equal(TaskId, maps:get(task_id, RunContext, undefined)),
    ok = assert_equal(explore_run,
                      maps:get(purpose, RunContext, undefined)),
    ok = assert_equal(true, is_process_alive(WorkerPid)),
    ok = assert_equal(true, ActorPid =/= RunPid),
    ok = assert_equal(true, ActorPid =/= WorkerPid),
    ok = assert_equal(true, RunPid =/= WorkerPid),
    ok.

reader_then_terminal_run_steps_carries_observation_and_outputs(_Config) ->
    Store = event_store_pid(),
    TestPid = self(),
    ExploreSource =
        <<"(explore (step (id inspect) (tool text_head) "
          "(args (text \"observed\") (lines 1))))">>,
    TerminalSource =
        <<"(run-steps (step (id finish) (tool echo) "
          "(args (value \"done\"))))">>,
    FirstResponse = fixed_response(ExploreSource),
    SecondResponse = fixed_response(TerminalSource),
    FirstResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 1, CallOpts},
                FirstResponse
        end,
    SecondResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 2, CallOpts},
                SecondResponse
        end,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence => [FirstResponder, SecondResponder]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-loop-spine">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [text_head, echo]},
            event_store => Store}),
    TaskId = <<"task-explore-loop-spine">>,
    CorrelationId = <<"corr-explore-loop-spine">>,
    Prompt = <<"inspect, then finish">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => Prompt},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    FirstCallOpts = wait_for_provider_request(1),
    SecondCallOpts = wait_for_provider_request(2),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),

    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt}] =
        maps:get(messages, FirstCallOpts),
    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    ExpectedObservation =
        <<"(observation (status completed) "
          "(outputs (step (id inspect) "
          "(output \"((text \\\"observed\\\") (truncated false))\"))))">>,
    ok = assert_equal(ExpectedObservation, Observation),
    ok = assert_equal({ok, #{finish => #{value => <<"done">>}}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

fixed_response(Content) ->
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Content}}]})),
    {200, Body}.

wait_for_provider_request(Round) ->
    receive
        {provider_request, Round, CallOpts} ->
            CallOpts
    after 2000 ->
        ct:fail({provider_request_timeout, Round})
    end.

wait_for_task_status(_ActorPid, _TaskId, Status, 0) ->
    ct:fail({task_status_timeout, Status});
wait_for_task_status(ActorPid, TaskId, Status, N) ->
    case soma_actor:get_task_status(ActorPid, TaskId) of
        #{status := Status} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_task_status(ActorPid, TaskId, Status, N - 1)
    end.

assert_equal(Expected, Actual) when Expected =:= Actual ->
    ok;
assert_equal(Expected, Actual) ->
    ct:fail({assert_equal, [{expected, Expected}, {actual, Actual}]}).

wait_for_event(_Store, _CorrelationId, EventType, 0) ->
    error({timeout, EventType});
wait_for_event(Store, CorrelationId, EventType, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    case lists:any(
           fun(Event) -> maps:get(event_type, Event, undefined) =:= EventType end,
           Events) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_event(Store, CorrelationId, EventType, N - 1)
    end.

wait_for_event_map(_Store, _CorrelationId, _EventType, 0) ->
    undefined;
wait_for_event_map(Store, CorrelationId, EventType, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    case [Event || Event <- Events,
                   maps:get(event_type, Event, undefined) =:= EventType] of
        [Event | _] ->
            Event;
        [] ->
            timer:sleep(20),
            wait_for_event_map(Store, CorrelationId, EventType, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
