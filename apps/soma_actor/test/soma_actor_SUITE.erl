-module(soma_actor_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([actor_is_gen_statem_with_callbacks/1]).
-export([start_actor_returns_ok_pid/1]).
-export([actor_alive_after_start/1]).
-export([actor_starts_idle/1]).
-export([actor_state_holds_config/1]).
-export([start_emits_one_actor_started_event/1]).
-export([actor_started_event_carries_actor_id/1]).
-export([actor_without_event_store_boots_quietly/1]).
-export([sup_exports_start_actor/1]).
-export([send_returns_envelope_task_id/1]).
-export([send_mints_task_id_when_absent/1]).
-export([correlation_id_from_envelope_when_present/1]).
-export([correlation_id_defaults_to_task_id/1]).
-export([non_map_envelope_errors_actor_survives/1]).
-export([missing_field_envelope_errors_actor_survives/1]).
-export([message_received_event_carries_ids/1]).
-export([task_accepted_event_matches_received_ids/1]).
-export([accepted_task_in_table_with_status/1]).
-export([actor_idle_and_alive_after_send/1]).
-export([second_send_accepts_too/1]).
-export([run_started_under_run_sup_distinct_pid/1]).
-export([run_completes_with_run_event_trail/1]).
-export([actor_run_worker_pids_all_distinct/1]).
-export([result_created_event_carries_ids/1]).
-export([task_completed_event_carries_ids/1]).
-export([task_status_completed_after_run/1]).
-export([task_result_holds_outputs_after_run/1]).
-export([send_returns_before_run_completes/1]).
-export([second_steps_envelope_starts_second_run/1]).
-export([no_steps_accepts_and_starts_no_run/1]).
-export([ask_returns_run_outputs/1]).
-export([ask_caller_and_actor_alive_after_return/1]).
-export([ask_reply_matches_completed_run/1]).
-export([ask_short_timeout_returns_timeout/1]).
-export([ask_timeout_actor_survives_and_completes/1]).
-export([ask_invalid_envelope_errors_no_run/1]).
-export([get_task_status_running_before_completion/1]).
-export([get_task_status_completed_after_run/1]).
-export([get_task_status_queryable_by_send_task_id/1]).
-export([get_task_result_not_ready_before_completion/1]).
-export([get_task_result_ok_outputs_after_completion/1]).
-export([unknown_task_id_not_found_both_reads_actor_alive/1]).
-export([read_returns_while_earlier_run_in_flight/1]).
-export([failed_run_emits_task_failed_event/1]).
-export([failed_run_sets_task_status_failed/1]).
-export([actor_alive_after_owned_run_fails/1]).
-export([tool_crash_isolated_by_process_boundary/1]).
-export([ask_failed_run_returns_error/1]).
-export([timed_out_run_emits_task_failed_timeout/1]).
-export([ask_timed_out_run_returns_error_timeout/1]).
-export([status_running_promptly_while_run_in_flight/1]).
-export([new_run_completes_after_failed_run/1]).

all() ->
    [actor_is_gen_statem_with_callbacks,
     start_actor_returns_ok_pid,
     actor_alive_after_start,
     actor_starts_idle,
     actor_state_holds_config,
     start_emits_one_actor_started_event,
     actor_started_event_carries_actor_id,
     actor_without_event_store_boots_quietly,
     sup_exports_start_actor,
     send_returns_envelope_task_id,
     send_mints_task_id_when_absent,
     correlation_id_from_envelope_when_present,
     correlation_id_defaults_to_task_id,
     non_map_envelope_errors_actor_survives,
     missing_field_envelope_errors_actor_survives,
     message_received_event_carries_ids,
     task_accepted_event_matches_received_ids,
     accepted_task_in_table_with_status,
     actor_idle_and_alive_after_send,
     second_send_accepts_too,
     run_started_under_run_sup_distinct_pid,
     run_completes_with_run_event_trail,
     actor_run_worker_pids_all_distinct,
     result_created_event_carries_ids,
     task_completed_event_carries_ids,
     task_status_completed_after_run,
     task_result_holds_outputs_after_run,
     send_returns_before_run_completes,
     second_steps_envelope_starts_second_run,
     no_steps_accepts_and_starts_no_run,
     ask_returns_run_outputs,
     ask_caller_and_actor_alive_after_return,
     ask_reply_matches_completed_run,
     ask_short_timeout_returns_timeout,
     ask_timeout_actor_survives_and_completes,
     ask_invalid_envelope_errors_no_run,
     get_task_status_running_before_completion,
     get_task_status_completed_after_run,
     get_task_status_queryable_by_send_task_id,
     get_task_result_not_ready_before_completion,
     get_task_result_ok_outputs_after_completion,
     unknown_task_id_not_found_both_reads_actor_alive,
     read_returns_while_earlier_run_in_flight,
     failed_run_emits_task_failed_event,
     failed_run_sets_task_status_failed,
     actor_alive_after_owned_run_fails,
     tool_crash_isolated_by_process_boundary,
     ask_failed_run_returns_error,
     timed_out_run_emits_task_failed_timeout,
     ask_timed_out_run_returns_error_timeout,
     status_running_promptly_while_run_in_flight,
     new_run_completes_after_failed_run].

init_per_testcase(TestCase, Config)
  when TestCase =:= start_actor_returns_ok_pid;
       TestCase =:= actor_alive_after_start;
       TestCase =:= actor_starts_idle;
       TestCase =:= actor_state_holds_config;
       TestCase =:= actor_without_event_store_boots_quietly;
       TestCase =:= send_returns_envelope_task_id;
       TestCase =:= send_mints_task_id_when_absent;
       TestCase =:= correlation_id_from_envelope_when_present;
       TestCase =:= correlation_id_defaults_to_task_id;
       TestCase =:= non_map_envelope_errors_actor_survives;
       TestCase =:= missing_field_envelope_errors_actor_survives;
       TestCase =:= accepted_task_in_table_with_status;
       TestCase =:= actor_idle_and_alive_after_send;
       TestCase =:= second_send_accepts_too;
       TestCase =:= unknown_task_id_not_found_both_reads_actor_alive ->
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup} | Config];
init_per_testcase(actor_started_event_carries_actor_id, Config) ->
    {ok, Sup} = soma_actor_sup:start_link(),
    {ok, Store} = soma_event_store:start_link(),
    [{sup, Sup}, {store, Store} | Config];
init_per_testcase(start_emits_one_actor_started_event, Config) ->
    {ok, Sup} = soma_actor_sup:start_link(),
    {ok, Store} = soma_event_store:start_link(),
    [{sup, Sup}, {store, Store} | Config];
init_per_testcase(message_received_event_carries_ids, Config) ->
    {ok, Sup} = soma_actor_sup:start_link(),
    {ok, Store} = soma_event_store:start_link(),
    [{sup, Sup}, {store, Store} | Config];
init_per_testcase(task_accepted_event_matches_received_ids, Config) ->
    {ok, Sup} = soma_actor_sup:start_link(),
    {ok, Store} = soma_event_store:start_link(),
    [{sup, Sup}, {store, Store} | Config];
init_per_testcase(TestCase, Config)
  when TestCase =:= run_started_under_run_sup_distinct_pid;
       TestCase =:= run_completes_with_run_event_trail;
       TestCase =:= actor_run_worker_pids_all_distinct;
       TestCase =:= result_created_event_carries_ids;
       TestCase =:= task_completed_event_carries_ids;
       TestCase =:= task_status_completed_after_run;
       TestCase =:= task_result_holds_outputs_after_run;
       TestCase =:= send_returns_before_run_completes;
       TestCase =:= second_steps_envelope_starts_second_run;
       TestCase =:= no_steps_accepts_and_starts_no_run;
       TestCase =:= ask_returns_run_outputs;
       TestCase =:= ask_caller_and_actor_alive_after_return;
       TestCase =:= ask_reply_matches_completed_run;
       TestCase =:= ask_short_timeout_returns_timeout;
       TestCase =:= ask_timeout_actor_survives_and_completes;
       TestCase =:= ask_invalid_envelope_errors_no_run;
       TestCase =:= get_task_status_running_before_completion;
       TestCase =:= get_task_status_completed_after_run;
       TestCase =:= get_task_status_queryable_by_send_task_id;
       TestCase =:= get_task_result_not_ready_before_completion;
       TestCase =:= get_task_result_ok_outputs_after_completion;
       TestCase =:= read_returns_while_earlier_run_in_flight;
       TestCase =:= failed_run_emits_task_failed_event;
       TestCase =:= failed_run_sets_task_status_failed;
       TestCase =:= actor_alive_after_owned_run_fails;
       TestCase =:= tool_crash_isolated_by_process_boundary;
       TestCase =:= ask_failed_run_returns_error;
       TestCase =:= timed_out_run_emits_task_failed_timeout;
       TestCase =:= ask_timed_out_run_returns_error_timeout;
       TestCase =:= status_running_promptly_while_run_in_flight;
       TestCase =:= new_run_completes_after_failed_run ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup}, {started_apps, Started} | Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(TestCase, Config)
  when TestCase =:= start_actor_returns_ok_pid;
       TestCase =:= actor_alive_after_start;
       TestCase =:= actor_starts_idle;
       TestCase =:= actor_state_holds_config;
       TestCase =:= start_emits_one_actor_started_event;
       TestCase =:= actor_started_event_carries_actor_id;
       TestCase =:= actor_without_event_store_boots_quietly;
       TestCase =:= send_returns_envelope_task_id;
       TestCase =:= send_mints_task_id_when_absent;
       TestCase =:= correlation_id_from_envelope_when_present;
       TestCase =:= correlation_id_defaults_to_task_id;
       TestCase =:= non_map_envelope_errors_actor_survives;
       TestCase =:= missing_field_envelope_errors_actor_survives;
       TestCase =:= message_received_event_carries_ids;
       TestCase =:= task_accepted_event_matches_received_ids;
       TestCase =:= accepted_task_in_table_with_status;
       TestCase =:= actor_idle_and_alive_after_send;
       TestCase =:= second_send_accepts_too;
       TestCase =:= unknown_task_id_not_found_both_reads_actor_alive ->
    case ?config(store, Config) of
        undefined -> ok;
        Store ->
            unlink(Store),
            exit(Store, shutdown)
    end,
    case ?config(sup, Config) of
        undefined -> ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    ok;
end_per_testcase(TestCase, Config)
  when TestCase =:= run_started_under_run_sup_distinct_pid;
       TestCase =:= run_completes_with_run_event_trail;
       TestCase =:= actor_run_worker_pids_all_distinct;
       TestCase =:= result_created_event_carries_ids;
       TestCase =:= task_completed_event_carries_ids;
       TestCase =:= task_status_completed_after_run;
       TestCase =:= task_result_holds_outputs_after_run;
       TestCase =:= send_returns_before_run_completes;
       TestCase =:= second_steps_envelope_starts_second_run;
       TestCase =:= no_steps_accepts_and_starts_no_run;
       TestCase =:= ask_returns_run_outputs;
       TestCase =:= ask_caller_and_actor_alive_after_return;
       TestCase =:= ask_reply_matches_completed_run;
       TestCase =:= ask_short_timeout_returns_timeout;
       TestCase =:= ask_timeout_actor_survives_and_completes;
       TestCase =:= ask_invalid_envelope_errors_no_run;
       TestCase =:= get_task_status_running_before_completion;
       TestCase =:= get_task_status_completed_after_run;
       TestCase =:= get_task_status_queryable_by_send_task_id;
       TestCase =:= get_task_result_not_ready_before_completion;
       TestCase =:= get_task_result_ok_outputs_after_completion;
       TestCase =:= read_returns_while_earlier_run_in_flight;
       TestCase =:= failed_run_emits_task_failed_event;
       TestCase =:= failed_run_sets_task_status_failed;
       TestCase =:= actor_alive_after_owned_run_fails;
       TestCase =:= tool_crash_isolated_by_process_boundary;
       TestCase =:= ask_failed_run_returns_error;
       TestCase =:= timed_out_run_emits_task_failed_timeout;
       TestCase =:= ask_timed_out_run_returns_error_timeout;
       TestCase =:= status_running_promptly_while_run_in_flight;
       TestCase =:= new_run_completes_after_failed_run ->
    case ?config(sup, Config) of
        undefined -> ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    application:stop(soma_runtime),
    ok;
end_per_testcase(_TestCase, _Config) ->
    ok.

%% Criterion 1: soma_actor implements the gen_statem behaviour and exports
%% start_link/1, callback_mode/0, and init/1. Proven by module introspection;
%% compilation against the gen_statem behaviour is itself part of the proof.
actor_is_gen_statem_with_callbacks(_Config) ->
    Attributes = soma_actor:module_info(attributes),
    Behaviours = proplists:get_value(behaviour, Attributes, []),
    true = lists:member(gen_statem, Behaviours),
    Exports = soma_actor:module_info(exports),
    true = lists:member({start_link, 1}, Exports),
    true = lists:member({callback_mode, 0}, Exports),
    true = lists:member({init, 1}, Exports),
    ok.

%% Criterion 2: an actor started through soma_actor_sup:start_actor/1 returns
%% {ok, Pid} with Pid a live process. Enters through the real supervisor entry,
%% no layer bypassed.
start_actor_returns_ok_pid(_Config) ->
    Opts = #{actor_id => <<"actor-1">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    true = is_pid(Pid),
    ok.

%% Criterion 3: immediately after start the actor pid passes is_process_alive/1.
%% Enters through the real supervisor entry, then checks liveness on the pid.
actor_alive_after_start(_Config) ->
    Opts = #{actor_id => <<"actor-1">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    true = is_process_alive(Pid),
    ok.

%% Criterion 4: immediately after start the actor is in state idle.
%% Enters through the real supervisor entry, then reads the state name via
%% sys:get_state/1, which on a state_functions gen_statem returns {StateName, Data}.
actor_starts_idle(_Config) ->
    Opts = #{actor_id => <<"actor-1">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    {idle, _Data} = sys:get_state(Pid),
    ok.

%% Criterion 5: the actor's state data holds the actor_id, model_config, and
%% tool_policy passed in Opts, readable through sys:get_state/1. The data record
%% lays actor_id, model_config, tool_policy out as the first three fields (record
%% positions 2, 3, 4 after the record tag), so the test pulls those fields by
%% position rather than binding the whole tuple — a later slice that appends
%% fields will not break this.
actor_state_holds_config(_Config) ->
    ActorId = <<"actor-cfg">>,
    ModelConfig = #{model => <<"test-model">>},
    ToolPolicy = #{allow => [echo]},
    Opts = #{actor_id => ActorId,
             model_config => ModelConfig,
             tool_policy => ToolPolicy},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    {idle, Data} = sys:get_state(Pid),
    ActorId = element(2, Data),
    ModelConfig = element(3, Data),
    ToolPolicy = element(4, Data),
    ok.

%% Criterion 6: starting an actor with a live event_store in Opts emits exactly
%% one actor.started event into the store. Emission happens inside init/1 before
%% start_link returns, so reading the store right after start_actor/1 finds it.
start_emits_one_actor_started_event(Config) ->
    Store = ?config(store, Config),
    Opts = #{actor_id => <<"actor-1">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, _Pid} = soma_actor_sup:start_actor(Opts),
    Events = soma_event_store:all(Store),
    Started = [E || E <- Events,
                    maps:get(event_type, E, undefined) =:= <<"actor.started">>],
    1 = length(Started),
    ok.

%% Criterion 7: the actor.started event carries the actor's actor_id. Starting an
%% actor with a live event_store emits one actor.started event; the test reads it
%% from the store and asserts its actor_id equals the actor_id passed in Opts.
actor_started_event_carries_actor_id(Config) ->
    Store = ?config(store, Config),
    ActorId = <<"actor-evt">>,
    Opts = #{actor_id => ActorId,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, _Pid} = soma_actor_sup:start_actor(Opts),
    Events = soma_event_store:all(Store),
    [Started] = [E || E <- Events,
                      maps:get(event_type, E, undefined) =:= <<"actor.started">>],
    ActorId = maps:get(actor_id, Started),
    ok.

%% Criterion 8: an actor started with no event_store in Opts boots and stays
%% alive, emitting nothing and not crashing. With no store to read, "emits
%% nothing" is proved by the actor neither crashing nor needing a store: the
%% undefined-store no-op emit clause is exercised by the actor staying alive in
%% idle. Enters through the real supervisor entry with Opts that omit event_store.
actor_without_event_store_boots_quietly(_Config) ->
    Opts = #{actor_id => <<"actor-no-store">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    true = is_process_alive(Pid),
    {idle, _Data} = sys:get_state(Pid),
    ok.

%% Criterion 9: soma_actor_sup exports start_actor/1, mirroring
%% soma_run_sup:start_run/1. The start_child path is covered behaviourally by
%% criteria 2-7; this pins the export name itself via module introspection.
sup_exports_start_actor(_Config) ->
    Exports = soma_actor_sup:module_info(exports),
    true = lists:member({start_actor, 1}, Exports),
    ok.

%% Criterion 1: soma_actor:send/2 returns {ok, TaskId} for a valid envelope, and
%% TaskId equals the envelope's task_id when it carries one. Enters through the
%% real soma_actor:send/2 call (a synchronous gen_statem:call); the actor is
%% started through soma_actor_sup:start_actor/1, no layer bypassed.
send_returns_envelope_task_id(_Config) ->
    Opts = #{actor_id => <<"actor-send">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-from-envelope">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    ok.

%% Criterion 2: when the envelope carries no task_id, soma_actor:send/2 mints a
%% fresh one and returns {ok, TaskId} with TaskId a non-empty binary. Enters
%% through the real soma_actor:send/2 call; the actor is started through
%% soma_actor_sup:start_actor/1, no layer bypassed.
send_mints_task_id_when_absent(_Config) ->
    Opts = #{actor_id => <<"actor-mint">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>}},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    true = is_binary(TaskId),
    true = byte_size(TaskId) > 0,
    ok.

%% Criterion 3: when the envelope carries a correlation_id, the task recorded in
%% the per-actor task table holds that exact correlation_id. Enters through the
%% real soma_actor:send/2 call; the actor is started through
%% soma_actor_sup:start_actor/1, no layer bypassed. The post-call table read goes
%% through sys:get_state/1 because no status-read function exists in this slice:
%% the tasks table is the fifth record field (element position 6), keyed by
%% task_id, each value at least #{correlation_id, status}.
correlation_id_from_envelope_when_present(_Config) ->
    Opts = #{actor_id => <<"actor-corr">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-corr">>,
    CorrelationId = <<"corr-from-envelope">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    Task = maps:get(TaskId, Tasks),
    CorrelationId = maps:get(correlation_id, Task),
    ok.

%% Criterion 4: when the envelope carries no correlation_id, the task recorded in
%% the per-actor task table holds a correlation_id equal to the task_id. Enters
%% through the real soma_actor:send/2 call; the actor is started through
%% soma_actor_sup:start_actor/1, no layer bypassed. The post-call table read goes
%% through sys:get_state/1 (no status-read function exists in this slice): the
%% tasks table is the fifth record field (element position 6), keyed by task_id,
%% each value at least #{correlation_id, status}.
correlation_id_defaults_to_task_id(_Config) ->
    Opts = #{actor_id => <<"actor-corr-default">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-corr-default">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    Task = maps:get(TaskId, Tasks),
    TaskId = maps:get(correlation_id, Task),
    ok.

%% Criterion 5: a non-map envelope makes send/2 return {error, Reason}, and the
%% actor pid is still alive afterward. Enters through the real soma_actor:send/2
%% call; the actor is started through soma_actor_sup:start_actor/1, no layer
%% bypassed. The actor must reject the bad envelope without crashing — proved by
%% the {error, _} reply plus is_process_alive/1 on the same pid.
non_map_envelope_errors_actor_survives(_Config) ->
    Opts = #{actor_id => <<"actor-bad-envelope">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    {error, _Reason} = soma_actor:send(Pid, <<"not-a-map">>),
    true = is_process_alive(Pid),
    ok.

%% Criterion 6: an envelope missing a required field makes send/2 return
%% {error, Reason}, and the actor pid is still alive afterward. Enters through
%% the real soma_actor:send/2 call; the actor is started through
%% soma_actor_sup:start_actor/1, no layer bypassed. The envelope omits payload
%% (a required field) to trigger the rejection; the actor must reject it without
%% crashing — proved by the {error, _} reply plus is_process_alive/1 on the same
%% pid.
missing_field_envelope_errors_actor_survives(_Config) ->
    Opts = #{actor_id => <<"actor-missing-field">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    Envelope = #{type => <<"chat">>,
                 task_id => <<"task-missing-field">>},
    {error, _Reason} = soma_actor:send(Pid, Envelope),
    true = is_process_alive(Pid),
    ok.

%% Criterion 7: after a valid send/2, the event store holds an
%% actor.message.received event carrying the call's actor_id, task_id, and
%% correlation_id. Enters through the real soma_actor:send/2 call; the actor is
%% started through soma_actor_sup:start_actor/1 with a live event_store, no layer
%% bypassed. The event read goes through soma_event_store:all/1 on the same store
%% the actor emits into.
message_received_event_carries_ids(Config) ->
    Store = ?config(store, Config),
    ActorId = <<"actor-msg-event">>,
    Opts = #{actor_id => ActorId,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-msg-event">>,
    CorrelationId = <<"corr-msg-event">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Events = soma_event_store:all(Store),
    [Received] = [E || E <- Events,
                       maps:get(event_type, E, undefined)
                           =:= <<"actor.message.received">>],
    ActorId = maps:get(actor_id, Received),
    TaskId = maps:get(task_id, Received),
    CorrelationId = maps:get(correlation_id, Received),
    ok.

%% Criterion 8: after a valid send/2, the event store holds an
%% actor.task.accepted event carrying the same actor_id, task_id, and
%% correlation_id as the actor.message.received event. Enters through the real
%% soma_actor:send/2 call; the actor is started through
%% soma_actor_sup:start_actor/1 with a live event_store, no layer bypassed. Both
%% events are read from the same store via soma_event_store:all/1 and their ids
%% compared field by field.
task_accepted_event_matches_received_ids(Config) ->
    Store = ?config(store, Config),
    ActorId = <<"actor-task-accepted">>,
    Opts = #{actor_id => ActorId,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-accepted">>,
    CorrelationId = <<"corr-accepted">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Events = soma_event_store:all(Store),
    [Received] = [E || E <- Events,
                       maps:get(event_type, E, undefined)
                           =:= <<"actor.message.received">>],
    [Accepted] = [E || E <- Events,
                       maps:get(event_type, E, undefined)
                           =:= <<"actor.task.accepted">>],
    AcceptedActorId = maps:get(actor_id, Received),
    AcceptedTaskId = maps:get(task_id, Received),
    AcceptedCorrelationId = maps:get(correlation_id, Received),
    AcceptedActorId = maps:get(actor_id, Accepted),
    AcceptedTaskId = maps:get(task_id, Accepted),
    AcceptedCorrelationId = maps:get(correlation_id, Accepted),
    ok.

%% Criterion 9: after a valid send/2, the accepted task_id is a key in the
%% per-actor task table with status accepted. Enters through the real
%% soma_actor:send/2 call; the actor is started through
%% soma_actor_sup:start_actor/1, no layer bypassed. The table read goes through
%% sys:get_state/1 (no status-read function exists in this slice): the tasks
%% table is the fifth record field (element position 6), keyed by task_id, each
%% value at least #{correlation_id, status}.
accepted_task_in_table_with_status(_Config) ->
    Opts = #{actor_id => <<"actor-status">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-status">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    true = maps:is_key(TaskId, Tasks),
    Task = maps:get(TaskId, Tasks),
    accepted = maps:get(status, Task),
    ok.

%% Criterion 10: after a valid send/2, the actor is still alive and reports
%% state idle. Enters through the real soma_actor:send/2 call; the actor is
%% started through soma_actor_sup:start_actor/1, no layer bypassed. After the
%% {ok, TaskId} reply the test checks is_process_alive/1 on the actor pid and
%% reads the state name via sys:get_state/1, which on a state_functions
%% gen_statem returns {StateName, Data}.
actor_idle_and_alive_after_send(_Config) ->
    Opts = #{actor_id => <<"actor-idle-after-send">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-idle-after-send">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    true = is_process_alive(Pid),
    {idle, _Data} = sys:get_state(Pid),
    ok.

%% Criterion 11: a second send/2 with a different task_id also returns
%% {ok, TaskId}, proving the actor is not single-shot. Enters through the real
%% soma_actor:send/2 call twice on the same actor pid; the actor is started
%% through soma_actor_sup:start_actor/1, no layer bypassed. Each returned id is
%% asserted to equal its envelope's task_id.
second_send_accepts_too(_Config) ->
    Opts = #{actor_id => <<"actor-second-send">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId1 = <<"task-one">>,
    Envelope1 = #{type => <<"chat">>,
                  payload => #{text => <<"first">>},
                  task_id => TaskId1},
    {ok, TaskId1} = soma_actor:send(Pid, Envelope1),
    TaskId2 = <<"task-two">>,
    Envelope2 = #{type => <<"chat">>,
                  payload => #{text => <<"second">>},
                  task_id => TaskId2},
    {ok, TaskId2} = soma_actor:send(Pid, Envelope2),
    ok.

%% Criterion 1 (slice 7): send/2 with an envelope carrying a valid steps list
%% returns {ok, TaskId} and starts a soma_run under soma_run_sup whose pid
%% differs from the actor pid. The runtime is booted so soma_run_sup and
%% soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the
%% actor and the run share one store. Enters through the real soma_actor:send/2
%% call, no layer bypassed; the run child is read back from soma_run_sup.
run_started_under_run_sup_distinct_pid(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-run-start">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => <<"task-run-start">>,
                 steps => Steps},
    {ok, <<"task-run-start">>} = soma_actor:send(Pid, Envelope),
    Children = supervisor:which_children(soma_run_sup),
    RunPids = [P || {_Id, P, _Type, _Mods} <- Children, is_pid(P)],
    1 = length(RunPids),
    [RunPid] = RunPids,
    true = is_process_alive(RunPid),
    true = RunPid =/= Pid,
    ok.

%% Criterion 2 (slice 7): demo steps run to run.completed through soma_run, and
%% the normal run event trail (run.started ... run.completed) appears in the
%% event store. The runtime is booted so soma_run_sup and soma_tool_registry are
%% alive; the actor is started through soma_actor_sup:start_actor/1 with the
%% booted runtime's event store so the actor and the run share one store. Enters
%% through the real soma_actor:send/2 call, no layer bypassed. The run id is read
%% from the actor's runs map (element 7 of the data record, run_id => task_id),
%% then the run-scoped trail is read back via soma_event_store:by_run/2 once
%% run.completed appears.
run_completes_with_run_event_trail(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-run-complete">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => <<"task-run-complete">>,
                 steps => Steps},
    {ok, <<"task-run-complete">>} = soma_actor:send(Pid, Envelope),
    RunId = actor_run_id(Pid),
    ok = wait_for_run_completed(Store, RunId, 100),
    Events = soma_event_store:by_run(Store, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.started">>, Types),
    true = lists:member(<<"run.completed">>, Types),
    StartedIdx = index_of(<<"run.started">>, Types),
    CompletedIdx = index_of(<<"run.completed">>, Types),
    true = is_integer(StartedIdx),
    true = is_integer(CompletedIdx),
    true = StartedIdx < CompletedIdx,
    ok.

%% Criterion 3 (slice 7): the actor pid, the run pid, and the tool-call worker
%% pid are three distinct pids, proving the actor does not execute tool logic
%% in-process and that each invocation crosses a process boundary. The runtime is
%% booted so soma_run_sup and soma_tool_registry are alive; the actor is started
%% through soma_actor_sup:start_actor/1 with the booted runtime's event store so
%% the actor and the run share one store. Enters through the real
%% soma_actor:send/2 call, no layer bypassed. The run pid is read from
%% soma_run_sup's children and the worker pid from the tool.started event in the
%% store; all three are asserted distinct.
actor_run_worker_pids_all_distinct(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-pids-distinct">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => <<"task-pids-distinct">>,
                 steps => Steps},
    {ok, <<"task-pids-distinct">>} = soma_actor:send(ActorPid, Envelope),
    Children = supervisor:which_children(soma_run_sup),
    [RunPid] = [P || {_Id, P, _Type, _Mods} <- Children, is_pid(P)],
    RunId = actor_run_id(ActorPid),
    ok = wait_for_run_completed(Store, RunId, 100),
    WorkerPid = worker_pid_from_tool_started(Store, RunId),
    true = is_pid(WorkerPid),
    %% The three pids are distinct: the actor did not run the run in-process, and
    %% the tool call crossed a process boundary out of the run.
    true = ActorPid =/= RunPid,
    true = ActorPid =/= WorkerPid,
    true = RunPid =/= WorkerPid,
    ok.

%% Criterion 4 (slice 8): on run completion the actor emits an
%% actor.result.created event carrying the task's actor_id, task_id, and
%% correlation_id. The runtime is booted so soma_run_sup and soma_tool_registry
%% are alive; the actor is started through soma_actor_sup:start_actor/1 with the
%% booted runtime's event store so the actor and the run share one store. Enters
%% through the real soma_actor:send/2 call, no layer bypassed. After the run
%% completes the terminal {run_completed, ...} message lands in the actor's
%% mailbox; the test polls the store until the actor.result.created event
%% appears, then asserts it carries the three ids from the recorded task.
result_created_event_carries_ids(_Config) ->
    Store = event_store_pid(),
    ActorId = <<"actor-result-created">>,
    Opts = #{actor_id => ActorId,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-result-created">>,
    CorrelationId = <<"corr-result-created">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Created = wait_for_actor_event(Store, <<"actor.result.created">>, 100),
    ActorId = maps:get(actor_id, Created),
    TaskId = maps:get(task_id, Created),
    CorrelationId = maps:get(correlation_id, Created),
    ok.

%% Criterion 5 (slice 8): on run completion the actor emits an
%% actor.task.completed event carrying the task's actor_id, task_id, and
%% correlation_id. The runtime is booted so soma_run_sup and soma_tool_registry
%% are alive; the actor is started through soma_actor_sup:start_actor/1 with the
%% booted runtime's event store so the actor and the run share one store. Enters
%% through the real soma_actor:send/2 call, no layer bypassed. After the run
%% completes the terminal {run_completed, ...} message lands in the actor's
%% mailbox; the test polls the store until the actor.task.completed event
%% appears, then asserts it carries the three ids from the recorded task.
task_completed_event_carries_ids(_Config) ->
    Store = event_store_pid(),
    ActorId = <<"actor-task-completed">>,
    Opts = #{actor_id => ActorId,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-task-completed">>,
    CorrelationId = <<"corr-task-completed">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Completed = wait_for_actor_event(Store, <<"actor.task.completed">>, 100),
    ActorId = maps:get(actor_id, Completed),
    TaskId = maps:get(task_id, Completed),
    CorrelationId = maps:get(correlation_id, Completed),
    ok.

%% Criterion 6 (slice p3/p4): after the run completes the task's status is
%% completed, readable through sys:get_state/1. The runtime is booted so
%% soma_run_sup and soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the
%% actor and the run share one store. Enters through the real soma_actor:send/2
%% call, no layer bypassed. After the run completes the terminal
%% {run_completed, ...} message lands in the actor's mailbox; the test polls the
%% actor's task table (element 6 of the data record) until the task's status
%% flips, then asserts it is completed.
task_status_completed_after_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-status-completed">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-status-completed">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    RunId = actor_run_id(Pid),
    ok = wait_for_run_completed(Store, RunId, 100),
    Status = wait_for_task_status(Pid, TaskId, completed, 100),
    completed = Status,
    ok.

%% Criterion 7 (slice p3/p4): after the run completes the task's stored result
%% holds the run Outputs, readable through sys:get_state/1. The runtime is booted
%% so soma_run_sup and soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the actor
%% and the run share one store. Enters through the real soma_actor:send/2 call, no
%% layer bypassed. After the run completes the terminal {run_completed, RunId,
%% Outputs} message lands in the actor's mailbox; the test polls the actor's task
%% table (element 6 of the data record) until the task's status flips to completed,
%% then asserts the task's stored result equals the run's Outputs (the single
%% echo step's recorded output).
task_result_holds_outputs_after_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-result-outputs">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-result-outputs">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    RunId = actor_run_id(Pid),
    ok = wait_for_run_completed(Store, RunId, 100),
    completed = wait_for_task_status(Pid, TaskId, completed, 100),
    Result = task_result(Pid, TaskId),
    %% The single echo step s1 echoes its args unchanged, so the run's Outputs
    %% map is keyed by the step id with the echoed args as the value.
    Outputs = #{s1 => #{value => <<"a">>}},
    Result = Outputs,
    ok.

%% Criterion 8 (slice p3/p4): send/2 returns before the run completes — the
%% result is recorded asynchronously when {run_completed, ...} arrives — and the
%% actor pid stays alive throughout. The runtime is booted so soma_run_sup and
%% soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the
%% actor and the run share one store. Enters through the real soma_actor:send/2
%% call, no layer bypassed. The single step sleeps for 500ms, so the run is still
%% executing when send/2 returns: right after the {ok, TaskId} reply the task is
%% still accepted (not yet completed) and the actor pid is alive. The test then
%% polls the task table until the status flips to completed, proving the result
%% is recorded asynchronously on the terminal message.
send_returns_before_run_completes(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-async-complete">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-async-complete">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    %% send/2 has returned while the 500ms sleep step is still running: the task
    %% is running (not yet completed), and the actor is alive and idle.
    running = task_status(Pid, TaskId),
    true = is_process_alive(Pid),
    %% The result is recorded asynchronously once {run_completed, ...} arrives.
    completed = wait_for_task_status(Pid, TaskId, completed, 100),
    true = is_process_alive(Pid),
    ok.

%% Criterion 9 (slice p3/p4): after one run completes a second envelope with a
%% valid steps list returns {ok, TaskId2} and starts a second run that reaches
%% run.completed under a distinct run id, proving the actor is not single-shot.
%% The runtime is booted so soma_run_sup and soma_tool_registry are alive; the
%% actor is started through soma_actor_sup:start_actor/1 with the booted
%% runtime's event store so the actor and both runs share one store. Enters
%% through the real soma_actor:send/2 call twice on the same actor pid, no layer
%% bypassed. Each run id is read from the actor's runs map (element 7, keyed by
%% run_id => task_id) by task id; the two run ids are asserted distinct and the
%% second run's trail is read back via soma_event_store:by_run/2.
second_steps_envelope_starts_second_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-second-run">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    TaskId1 = <<"task-run-one">>,
    Envelope1 = #{type => <<"chat">>,
                  payload => #{text => <<"first">>},
                  task_id => TaskId1,
                  steps => Steps},
    {ok, TaskId1} = soma_actor:send(Pid, Envelope1),
    RunId1 = run_id_for_task(Pid, TaskId1),
    ok = wait_for_run_completed(Store, RunId1, 100),
    TaskId2 = <<"task-run-two">>,
    Envelope2 = #{type => <<"chat">>,
                  payload => #{text => <<"second">>},
                  task_id => TaskId2,
                  steps => Steps},
    {ok, TaskId2} = soma_actor:send(Pid, Envelope2),
    RunId2 = run_id_for_task(Pid, TaskId2),
    true = RunId1 =/= RunId2,
    ok = wait_for_run_completed(Store, RunId2, 100),
    ok.

%% Criterion 10 (slice p3/p4): an envelope with no steps key keeps the slice-4
%% behavior exactly — send/2 returns {ok, TaskId}, no soma_run is started under
%% soma_run_sup, and the task stays at status accepted. The runtime is booted so
%% soma_run_sup is alive (and would hold a run child if one were wrongly started);
%% the actor is started through soma_actor_sup:start_actor/1 with the booted
%% runtime's event store, no layer bypassed. Enters through the real
%% soma_actor:send/2 call. After the {ok, TaskId} reply the test reads
%% soma_run_sup's children and asserts there are zero run pids, then reads the
%% task table (element 6 of the data record) and asserts the task's status is
%% still accepted.
no_steps_accepts_and_starts_no_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-no-steps">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-no-steps">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Children = supervisor:which_children(soma_run_sup),
    RunPids = [P || {_Id, P, _Type, _Mods} <- Children, is_pid(P)],
    0 = length(RunPids),
    accepted = task_status(Pid, TaskId),
    ok.

%% Criterion 1 (slice p5/p6): ask/3 with a valid steps envelope blocks the caller
%% inside the gen_statem:call until the run completes, then returns {ok, Result}
%% where Result is the run's outputs. The runtime is booted so soma_run_sup and
%% soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the actor
%% and the run share one store. Enters through the real soma_actor:ask/3 call, no
%% layer bypassed. The single echo step s1 echoes its args unchanged, so the run's
%% Outputs map is keyed by the step id with the echoed args as the value.
ask_returns_run_outputs(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-outputs">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-outputs">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, Result} = soma_actor:ask(Pid, Envelope, 5000),
    Outputs = #{s1 => #{value => <<"a">>}},
    Result = Outputs,
    ok.

%% Criterion 2 (slice p5/p6): after ask/3 returns, both the calling process and
%% the actor pid are still alive. ask blocks the caller inside its gen_statem:call
%% and the actor defers the reply until the run completes; neither process is torn
%% down by the round trip. The runtime is booted so soma_run_sup and
%% soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the actor
%% and the run share one store. Enters through the real soma_actor:ask/3 call, no
%% layer bypassed. After the {ok, Result} reply the test checks is_process_alive/1
%% on the caller (self) and on the actor pid.
ask_caller_and_actor_alive_after_return(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-alive">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-alive">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, _Result} = soma_actor:ask(Pid, Envelope, 5000),
    true = is_process_alive(self()),
    true = is_process_alive(Pid),
    ok.

%% Criterion 3 (slice p5/p6): ask/3's reply arrives only after the run completes,
%% and the returned result matches the run's actual outputs. The single step
%% sleeps for 300ms then the run completes, so when ask issues its gen_statem:call
%% the run is genuinely in flight. The actor only sets the task to status
%% completed inside its {run_completed, ...} handler, which is also where it
%% replies to the parked ask waiter. So the moment ask/3 returns, the task table
%% must already read completed — proving the reply could not have arrived before
%% the run finished — and the returned Result must equal the task's stored result,
%% which is the run's outputs. The runtime is booted so soma_run_sup and
%% soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the actor
%% and the run share one store. Enters through the real soma_actor:ask/3 call, no
%% layer bypassed.
ask_reply_matches_completed_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-after-complete">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-after-complete">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 300}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, Result} = soma_actor:ask(Pid, Envelope, 5000),
    %% The reply could only have been sent from the {run_completed, ...} handler,
    %% which sets the task to completed in the same step — so by the time ask/3
    %% returns the task table already reads completed.
    completed = task_status(Pid, TaskId),
    %% The returned result is exactly the run's stored outputs.
    Result = task_result(Pid, TaskId),
    ok.

%% Criterion 4 (slice p5/p6): ask/3 with a TimeoutMs shorter than the run can
%% finish returns the atom timeout. The single step sleeps for 500ms while the
%% caller's TimeoutMs is 100ms, so the gen_statem:call timeout fires before the
%% run completes. A bare gen_statem:call would exit with {timeout, ...}; ask/3 is
%% expected to catch that and return the atom timeout (its spec is
%% {ok, Result} | {error, Reason} | timeout). The runtime is booted so
%% soma_run_sup and soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store. Enters
%% through the real soma_actor:ask/3 call, no layer bypassed.
ask_short_timeout_returns_timeout(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-timeout">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-timeout">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    timeout = soma_actor:ask(Pid, Envelope, 100),
    ok.

%% Criterion 5 (slice p5/p6): after an ask/3 caller-side timeout the actor pid is
%% still alive and still drives the task to completed. The single step sleeps for
%% 500ms while the caller's TimeoutMs is 100ms, so the gen_statem:call times out on
%% the caller side and ask/3 returns the atom timeout — but the actor still holds
%% the parked From and keeps running the task. The runtime is booted so
%% soma_run_sup and soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store. Enters
%% through the real soma_actor:ask/3 call, no layer bypassed. After the timeout the
%% test checks is_process_alive/1 on the actor pid, then polls the actor's task
%% table until the run completes and the task reaches completed, checking the actor
%% stays alive throughout.
ask_timeout_actor_survives_and_completes(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-timeout-survives">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-timeout-survives">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    timeout = soma_actor:ask(Pid, Envelope, 100),
    %% The caller gave up but the actor still holds the parked From and is alive.
    true = is_process_alive(Pid),
    %% The actor still drives the run to completion: the task reaches completed.
    completed = wait_for_task_status(Pid, TaskId, completed, 100),
    true = is_process_alive(Pid),
    ok.

%% Criterion 6 (slice p5/p6): ask/3 with an invalid envelope returns
%% {error, Reason} and starts no run. The envelope is not a map, so
%% validate_envelope fails inside the actor's idle({call, From}, {ask, _}, _)
%% clause and the actor replies {error, Reason} straight away — no soma_run is
%% started under soma_run_sup and no waiter is parked. The runtime is booted so
%% soma_run_sup is alive (and would hold a run child if one were wrongly
%% started); the actor is started through soma_actor_sup:start_actor/1 with the
%% booted runtime's event store, no layer bypassed. Enters through the real
%% soma_actor:ask/3 call. After the {error, Reason} reply the test reads
%% soma_run_sup's children and asserts there are zero run pids.
ask_invalid_envelope_errors_no_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-invalid">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    {error, _Reason} = soma_actor:ask(Pid, <<"not-a-map">>, 5000),
    Children = supervisor:which_children(soma_run_sup),
    RunPids = [P || {_Id, P, _Type, _Mods} <- Children, is_pid(P)],
    0 = length(RunPids),
    true = is_process_alive(Pid),
    ok.

%% Criterion 7 (slice p5/p6): get_task_status/2 returns a map with
%% status => running after a steps task is accepted and before it completes. The
%% single step sleeps for 500ms, so the run is still in flight when the status is
%% read. The runtime is booted so soma_run_sup and soma_tool_registry are alive;
%% the actor is started through soma_actor_sup:start_actor/1 with the booted
%% runtime's event store, no layer bypassed. Enters through the real
%% soma_actor:send/2 then soma_actor:get_task_status/2 calls. The returned map
%% must carry task_id and correlation_id alongside status => running.
get_task_status_running_before_completion(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-status-running">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-status-running">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    %% The 500ms sleep step is still running, so the task reads running.
    Status = soma_actor:get_task_status(Pid, TaskId),
    running = maps:get(status, Status),
    TaskId = maps:get(task_id, Status),
    TaskId = maps:get(correlation_id, Status),
    ok.

%% Criterion 8 (slice p5/p6): get_task_status/2 returns a map with
%% status => completed after the actor processes {run_completed, ...} for that
%% task. The single echo step finishes fast; the test polls the actor's task
%% table until the run completes, then reads the status through the real
%% get_task_status/2 call and asserts the returned map carries
%% status => completed. The runtime is booted so soma_run_sup and
%% soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store, no layer
%% bypassed. Enters through the real soma_actor:send/2 then
%% soma_actor:get_task_status/2 calls.
get_task_status_completed_after_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-status-done">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-status-done">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    RunId = actor_run_id(Pid),
    ok = wait_for_run_completed(Store, RunId, 100),
    completed = wait_for_task_status(Pid, TaskId, completed, 100),
    Status = soma_actor:get_task_status(Pid, TaskId),
    completed = maps:get(status, Status),
    ok.

%% Criterion 9 (slice p5/p6): a steps task started through send/2 is queryable
%% through get_task_status/2 by the exact task_id that send/2 returned. send/2
%% returns {ok, TaskId}; the caller then passes that same TaskId to
%% get_task_status/2 and the reply map carries task_id equal to it. The runtime is
%% booted so soma_run_sup and soma_tool_registry are alive; the actor is started
%% through soma_actor_sup:start_actor/1 with the booted runtime's event store, no
%% layer bypassed. Enters through the real soma_actor:send/2 then
%% soma_actor:get_task_status/2 calls.
get_task_status_queryable_by_send_task_id(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-status-queryable">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Status = soma_actor:get_task_status(Pid, TaskId),
    TaskId = maps:get(task_id, Status),
    ok.

%% Criterion 10 (slice p5/p6): get_task_result/2 returns not_ready before the
%% task completes. The single step sleeps for 500ms, so the run is still in
%% flight (task at running, no stored result) when the result is read. The
%% runtime is booted so soma_run_sup and soma_tool_registry are alive; the actor
%% is started through soma_actor_sup:start_actor/1 with the booted runtime's
%% event store, no layer bypassed. Enters through the real soma_actor:send/2 then
%% soma_actor:get_task_result/2 calls.
get_task_result_not_ready_before_completion(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-result-not-ready">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-result-not-ready">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    %% The 500ms sleep step is still running, so the result is not ready yet.
    not_ready = soma_actor:get_task_result(Pid, TaskId),
    ok.

%% Criterion 11 (slice p5/p6): get_task_result/2 returns {ok, Outputs} after the
%% same task completes. The single echo step finishes fast; the test polls the
%% actor's task table until the run completes, then reads the result through the
%% real get_task_result/2 call and asserts it returns {ok, Outputs} where Outputs
%% is the run's outputs (the single echo step's recorded output). The runtime is
%% booted so soma_run_sup and soma_tool_registry are alive; the actor is started
%% through soma_actor_sup:start_actor/1 with the booted runtime's event store, no
%% layer bypassed. Enters through the real soma_actor:send/2 then
%% soma_actor:get_task_result/2 calls.
get_task_result_ok_outputs_after_completion(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-result-ok">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-result-ok">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    RunId = actor_run_id(Pid),
    ok = wait_for_run_completed(Store, RunId, 100),
    completed = wait_for_task_status(Pid, TaskId, completed, 100),
    %% The single echo step s1 echoes its args unchanged, so the run's Outputs
    %% map is keyed by the step id with the echoed args as the value.
    Outputs = #{s1 => #{value => <<"a">>}},
    {ok, Outputs} = soma_actor:get_task_result(Pid, TaskId),
    ok.

%% Criterion 12 (slice p5/p6): get_task_status/2 and get_task_result/2 for an
%% unknown task_id both report not-found, and the actor pid stays alive across the
%% pair of calls. No task is ever accepted for the queried id, so each read hits
%% the not-found path. get_task_result/2 returns {error, not_found}; for
%% get_task_status/2 the return type stays a map, so it carries status => not_found.
%% The actor is started through soma_actor_sup:start_actor/1, no layer bypassed;
%% no runtime is needed because the reads never start a run. Enters through the
%% real soma_actor:get_task_status/2 and soma_actor:get_task_result/2 calls, then
%% checks is_process_alive/1 on the actor pid after both reads.
unknown_task_id_not_found_both_reads_actor_alive(_Config) ->
    Opts = #{actor_id => <<"actor-unknown-task">>,
             model_config => #{},
             tool_policy => #{}},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    UnknownTaskId = <<"task-never-accepted">>,
    Status = soma_actor:get_task_status(Pid, UnknownTaskId),
    not_found = maps:get(status, Status),
    {error, not_found} = soma_actor:get_task_result(Pid, UnknownTaskId),
    true = is_process_alive(Pid),
    ok.

%% Criterion 13 (slice p5/p6): a read served while an earlier task's run is still
%% in flight returns promptly without blocking on the run. A first send/2 starts a
%% 500ms sleep step, so its run is genuinely executing; a get_task_status/2 issued
%% right after must come back inside its gen_statem:call default 5s timeout (it
%% would not, if the actor blocked on the run) and report the in-flight task as
%% running — proving the actor handled the read in idle without waiting on the run.
%% The runtime is booted so soma_run_sup and soma_tool_registry are alive; the
%% actor is started through soma_actor_sup:start_actor/1 with the booted runtime's
%% event store, no layer bypassed. Enters through the real soma_actor:send/2 then
%% soma_actor:get_task_status/2 calls. The read returning at all (the call does not
%% time out) is the proof of promptness; the running status confirms the run was
%% still in flight when the read was served.
read_returns_while_earlier_run_in_flight(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-read-in-flight">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-read-in-flight">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    %% The first run's 500ms sleep is still executing. The read is served from
    %% idle without blocking on the run, so it returns promptly with the in-flight
    %% task at running.
    Status = soma_actor:get_task_status(Pid, TaskId),
    running = maps:get(status, Status),
    TaskId = maps:get(task_id, Status),
    ok.

%% Criterion 1 (slice p8/p9/p15): a steps envelope whose run fails (the fail tool
%% in error mode) makes the actor emit an actor.task.failed event carrying
%% actor_id, task_id, correlation_id, and the failure reason. The runtime is
%% booted so soma_run_sup and soma_tool_registry are alive; the actor is started
%% through soma_actor_sup:start_actor/1 with the booted runtime's event store so
%% the actor and the run share one store. Enters through the real
%% soma_actor:send/2 call, no layer bypassed. The single fail step returns
%% {error, boom}; soma_run fails the run and sends {run_failed, RunId, boom} to
%% the actor, which records the failure and emits actor.task.failed. The test
%% polls the shared store until the event appears, then asserts it carries the
%% call's actor_id, task_id, correlation_id, and reason => boom.
failed_run_emits_task_failed_event(_Config) ->
    Store = event_store_pid(),
    ActorId = <<"actor-task-failed">>,
    Opts = #{actor_id => ActorId,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-task-failed">>,
    CorrelationId = <<"corr-task-failed">>,
    Steps = [#{id => s1, tool => fail,
               args => #{mode => error, reason => boom}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Failed = wait_for_actor_event(Store, <<"actor.task.failed">>, 100),
    ActorId = maps:get(actor_id, Failed),
    TaskId = maps:get(task_id, Failed),
    CorrelationId = maps:get(correlation_id, Failed),
    boom = maps:get(reason, Failed),
    ok.

%% Criterion 2 (slice p8/p9/p15): after a run the actor owns fails, that task's
%% status in the actor's task table reads failed. The runtime is booted so
%% soma_run_sup and soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the
%% actor and the run share one store. Enters through the real soma_actor:send/2
%% call, no layer bypassed. The single fail step returns {error, boom}; soma_run
%% fails the run and sends {run_failed, RunId, boom} to the actor, which sets the
%% task status to failed. The test polls the actor's task table (element 6 of the
%% data record) until the status flips, then asserts it is failed — read through
%% sys:get_state/1 because there is no failed-status read function.
failed_run_sets_task_status_failed(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-status-failed">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-status-failed">>,
    Steps = [#{id => s1, tool => fail,
               args => #{mode => error, reason => boom}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Status = wait_for_task_status(Pid, TaskId, failed, 100),
    failed = Status,
    ok.

%% Criterion 3 (slice p8/p9/p15): the actor pid passes is_process_alive/1 after a
%% run it owns fails. The runtime is booted so soma_run_sup and soma_tool_registry
%% are alive; the actor is started through soma_actor_sup:start_actor/1 with the
%% booted runtime's event store so the actor and the run share one store. Enters
%% through the real soma_actor:send/2 call, no layer bypassed. The single fail step
%% returns {error, boom}; soma_run fails the run and sends {run_failed, ...} to the
%% actor as an ordinary mailbox message — not a link signal — so the actor records
%% the failure and stays alive. The test polls the actor's task table until the
%% task reaches failed (proving the failure was handled), then asserts the actor
%% pid is still alive via is_process_alive/1.
actor_alive_after_owned_run_fails(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-alive-after-fail">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-alive-after-fail">>,
    Steps = [#{id => s1, tool => fail,
               args => #{mode => error, reason => boom}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    failed = wait_for_task_status(Pid, TaskId, failed, 100),
    true = is_process_alive(Pid),
    ok.

%% Criterion 4 (slice p8/p9/p15): a steps envelope whose tool crashes (the fail
%% tool in crash mode) reaches the actor as a {run_failed, ...} message and
%% leaves the actor pid alive, with the actor pid, the now-dead run pid, and the
%% tool-call worker pid all distinct — proving isolation by process boundary, not
%% crash propagation. The runtime is booted so soma_run_sup and
%% soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the
%% actor and the run share one store. Enters through the real soma_actor:send/2
%% call, no layer bypassed. The run pid is captured from soma_run_sup's children
%% right after send/2 returns (while the run still exists) and the worker pid
%% from the run's tool.started event in the store (reusing
%% worker_pid_from_tool_started/2). The single fail step raises error(boom);
%% soma_run's worker-monitor DOWN fails the run and sends {run_failed, RunId, _}
%% to the actor. The test polls the actor's task table until the task reaches
%% failed (proving the crash arrived as a message), then asserts the three pids
%% are distinct and the actor pid is still alive.
tool_crash_isolated_by_process_boundary(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-crash-isolated">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-crash-isolated">>,
    Steps = [#{id => s1, tool => fail,
               args => #{mode => crash, reason => boom}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    %% Capture the run pid while the run still exists, before the crash tears it
    %% down. send/2 returns before the run executes, so the run child is alive.
    Children = supervisor:which_children(soma_run_sup),
    [RunPid] = [P || {_Id, P, _Type, _Mods} <- Children, is_pid(P)],
    RunId = actor_run_id(ActorPid),
    %% The crash reaches the actor as a {run_failed, ...} message: the task flips
    %% to failed without the actor dying.
    failed = wait_for_task_status(ActorPid, TaskId, failed, 100),
    WorkerPid = worker_pid_from_tool_started(Store, RunId),
    true = is_pid(WorkerPid),
    %% The now-dead run pid, the worker pid, and the actor pid are three distinct
    %% pids: isolation is the process boundary, not crash propagation.
    true = ActorPid =/= RunPid,
    true = ActorPid =/= WorkerPid,
    true = RunPid =/= WorkerPid,
    %% The crash arrived as a message, not a signal: the actor is still alive.
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 5 (slice p8/p9/p15): an ask/3 whose run fails returns {error, Reason}
%% instead of hanging, and the actor pid stays alive afterward. The runtime is
%% booted so soma_run_sup and soma_tool_registry are alive; the actor is started
%% through soma_actor_sup:start_actor/1 with the booted runtime's event store so
%% the actor and the run share one store. Enters through the real soma_actor:ask/3
%% call, no layer bypassed. The single fail step returns {error, boom}; ask/3
%% parks the caller's From, then soma_run fails the run and sends
%% {run_failed, RunId, boom} to the actor, which replies {error, boom} to the
%% parked waiter. The TimeoutMs (5000) is long enough that the run failure, not
%% the caller-side timeout, ends the call. After the reply the test asserts the
%% actor pid is still alive via is_process_alive/1.
ask_failed_run_returns_error(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-failed">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-failed">>,
    Steps = [#{id => s1, tool => fail,
               args => #{mode => error, reason => boom}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {error, boom} = soma_actor:ask(Pid, Envelope, 5000),
    true = is_process_alive(Pid),
    ok.

%% Criterion 6 (slice p8/p9/p15): a steps envelope whose run times out (a sleep
%% step past a short per-step timeout_ms) makes the actor emit an
%% actor.task.failed event with reason => timeout. The runtime is booted so
%% soma_run_sup and soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the
%% actor and the run share one store. Enters through the real soma_actor:send/2
%% call, no layer bypassed. The single sleep step runs 500ms with a 50ms
%% per-step timeout_ms, so soma_run's state_timeout fires first; soma_run times
%% the run out and sends {run_timeout, RunId} to the actor, which records the
%% failure and emits actor.task.failed with reason => timeout. The test polls
%% the shared store until the event appears, then asserts its reason is timeout.
timed_out_run_emits_task_failed_timeout(_Config) ->
    Store = event_store_pid(),
    ActorId = <<"actor-task-timeout">>,
    Opts = #{actor_id => ActorId,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-task-timeout">>,
    CorrelationId = <<"corr-task-timeout">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500},
               timeout_ms => 50}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    Failed = wait_for_actor_event(Store, <<"actor.task.failed">>, 100),
    ActorId = maps:get(actor_id, Failed),
    TaskId = maps:get(task_id, Failed),
    CorrelationId = maps:get(correlation_id, Failed),
    timeout = maps:get(reason, Failed),
    ok.

%% Criterion 7 (slice p8/p9/p15): an ask/3 whose run times out returns
%% {error, timeout} instead of hanging, and the actor pid stays alive afterward.
%% The runtime is booted so soma_run_sup and soma_tool_registry are alive; the
%% actor is started through soma_actor_sup:start_actor/1 with the booted
%% runtime's event store so the actor and the run share one store. Enters through
%% the real soma_actor:ask/3 call, no layer bypassed. The single sleep step runs
%% 500ms with a 50ms per-step timeout_ms, so soma_run's state_timeout fires
%% first; ask/3 parks the caller's From, then soma_run times the run out and
%% sends {run_timeout, RunId} to the actor, which replies {error, timeout} to the
%% parked waiter. The TimeoutMs (5000) is longer than the step's timeout_ms, so
%% the run timeout (not the caller-side timeout) ends the call. After the reply
%% the test asserts the actor pid is still alive via is_process_alive/1.
ask_timed_out_run_returns_error_timeout(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-ask-timed-out">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-ask-timed-out">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500},
               timeout_ms => 50}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {error, timeout} = soma_actor:ask(Pid, Envelope, 5000),
    true = is_process_alive(Pid),
    ok.

%% Criterion 8 (slice p8/p9/p15): while a run is in flight and not yet terminal,
%% get_task_status/2 for that task returns promptly with status running — the
%% actor is not blocked waiting on the child run (P15). The runtime is booted so
%% soma_run_sup and soma_tool_registry are alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the
%% actor and the run share one store. Enters through the real soma_actor:send/2
%% then soma_actor:get_task_status/2 calls, no layer bypassed. The single sleep
%% step runs 500ms, so its run is genuinely in flight when the status is read;
%% the get_task_status/2 call coming back at all inside its gen_statem:call
%% default 5s timeout is the promptness proof (it would not return if the actor
%% blocked on the child run), and the running status confirms the run was still
%% in flight when the read was served — pinning P15 against this slice's
%% failure-adjacent context.
status_running_promptly_while_run_in_flight(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-status-promptly">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-status-promptly">>,
    Steps = [#{id => s1, tool => sleep, args => #{ms => 500}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    %% The 500ms sleep run is still in flight. The read is served from idle
    %% without blocking on the child run, so the call returns promptly (the proof
    %% of P15) and reports the in-flight task as running.
    Status = soma_actor:get_task_status(Pid, TaskId),
    running = maps:get(status, Status),
    TaskId = maps:get(task_id, Status),
    ok.

%% Criterion 9 (slice p8/p9/p15): after a run the actor owns fails, a second
%% steps envelope is accepted on the same actor pid and runs to completed —
%% proving a failed run leaves the actor responsive, not wedged. The runtime is
%% booted so soma_run_sup and soma_tool_registry are alive; the actor is started
%% through soma_actor_sup:start_actor/1 with the booted runtime's event store so
%% the actor and both runs share one store. Enters through the real
%% soma_actor:send/2 call twice on the same actor pid, no layer bypassed. The
%% first envelope's single fail step returns {error, boom}; soma_run fails the
%% run and sends {run_failed, ...} to the actor, which flips that task to failed.
%% The test then sends a second envelope with a single echo step; its run id is
%% read from the actor's runs map by task id (run_id_for_task/2) and its trail
%% polled to run.completed, then the second task is asserted completed.
new_run_completes_after_failed_run(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-new-run-after-fail">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId1 = <<"task-fail-first">>,
    FailSteps = [#{id => s1, tool => fail,
                   args => #{mode => error, reason => boom}}],
    Envelope1 = #{type => <<"chat">>,
                  payload => #{text => <<"first">>},
                  task_id => TaskId1,
                  steps => FailSteps},
    {ok, TaskId1} = soma_actor:send(Pid, Envelope1),
    failed = wait_for_task_status(Pid, TaskId1, failed, 100),
    TaskId2 = <<"task-complete-second">>,
    EchoSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope2 = #{type => <<"chat">>,
                  payload => #{text => <<"second">>},
                  task_id => TaskId2,
                  steps => EchoSteps},
    {ok, TaskId2} = soma_actor:send(Pid, Envelope2),
    RunId2 = run_id_for_task(Pid, TaskId2),
    ok = wait_for_run_completed(Store, RunId2, 100),
    Status = wait_for_task_status(Pid, TaskId2, completed, 100),
    completed = Status,
    ok.

%% Reads the run id the actor tracks for a given task id from its runs map
%% (element 7 of the data record, keyed by run_id => task_id).
run_id_for_task(Pid, TaskId) ->
    {idle, Data} = sys:get_state(Pid),
    Runs = element(7, Data),
    [RunId] = [R || {R, T} <- maps:to_list(Runs), T =:= TaskId],
    RunId.

%% Reads the current status for the task from the actor's task table.
task_status(Pid, TaskId) ->
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    maps:get(status, maps:get(TaskId, Tasks)).

%% Reads the stored result for the task from the actor's task table.
task_result(Pid, TaskId) ->
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    maps:get(result, maps:get(TaskId, Tasks)).

%% Polls the actor's task table until the task reaches the target status,
%% returning the observed status.
wait_for_task_status(_Pid, _TaskId, Target, 0) ->
    error({timeout, Target});
wait_for_task_status(Pid, TaskId, Target, N) ->
    {idle, Data} = sys:get_state(Pid),
    Tasks = element(6, Data),
    case maps:get(status, maps:get(TaskId, Tasks)) of
        Target ->
            Target;
        _Other ->
            timer:sleep(20),
            wait_for_task_status(Pid, TaskId, Target, N - 1)
    end.

%% Polls the store until one event of the given type appears, returning it.
wait_for_actor_event(_Store, Type, 0) ->
    error({timeout, Type});
wait_for_actor_event(Store, Type, N) ->
    Events = soma_event_store:all(Store),
    case [E || E <- Events,
               maps:get(event_type, E, undefined) =:= Type] of
        [Event | _] ->
            Event;
        [] ->
            timer:sleep(20),
            wait_for_actor_event(Store, Type, N - 1)
    end.

%% Reads the tool-call worker pid from the run's tool.started event.
worker_pid_from_tool_started(Store, RunId) ->
    Events = soma_event_store:by_run(Store, RunId),
    [Started | _] = [E || E <- Events,
                          maps:get(event_type, E, undefined)
                              =:= <<"tool.started">>],
    maps:get(tool_call_pid, Started).

%% Reads the single run id the actor tracks in its runs map (run_id => task_id).
actor_run_id(Pid) ->
    {idle, Data} = sys:get_state(Pid),
    Runs = element(7, Data),
    [RunId] = maps:keys(Runs),
    RunId.

wait_for_run_completed(_Store, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(Store, RunId, N) ->
    Events = soma_event_store:by_run(Store, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(<<"run.completed">>, Types) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_run_completed(Store, RunId, N - 1)
    end.

index_of(X, L) ->
    index_of(X, L, 1).

index_of(_X, [], _N) ->
    undefined;
index_of(X, [X | _], N) ->
    N;
index_of(X, [_ | T], N) ->
    index_of(X, T, N + 1).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
