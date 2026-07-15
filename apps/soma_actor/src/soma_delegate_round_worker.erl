%% @doc One disposable delegate decision/action round. It starts inert so its
%% coordinator can install the monitor and active-round identity before work.
-module(soma_delegate_round_worker).

-behaviour(gen_statem).

-export([start_link/1]).
-export([init/1, callback_mode/0, handle_event/4]).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

init(#{coordinator_pid := CoordinatorPid,
       task_id := TaskId,
       correlation_id := CorrelationId,
       round_id := RoundId,
       worker_identity := WorkerIdentity,
       result_capability := ResultCapability,
       work := Work})
  when is_pid(CoordinatorPid), is_binary(TaskId),
       is_binary(CorrelationId), is_integer(RoundId), RoundId > 0,
       is_binary(WorkerIdentity), is_reference(ResultCapability),
       is_map(Work) ->
    CoordinatorMRef = erlang:monitor(process, CoordinatorPid),
    Data = #{coordinator_pid => CoordinatorPid,
             coordinator_mref => CoordinatorMRef,
             task_id => TaskId,
             correlation_id => CorrelationId,
             round_id => RoundId,
             worker_identity => WorkerIdentity,
             result_capability => ResultCapability,
             work => Work},
    {ok, awaiting_start, Data}.

callback_mode() ->
    handle_event_function.

handle_event(info,
             {delegate_round_begin, TaskId, RoundId, WorkerIdentity,
              ResultCapability},
             awaiting_start,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability}) ->
    {next_state, running, Data};
handle_event(info,
             {'DOWN', CoordinatorMRef, process, CoordinatorPid, _Reason},
             _StateName,
             Data = #{coordinator_pid := CoordinatorPid,
                      coordinator_mref := CoordinatorMRef}) ->
    {stop, normal, Data};
handle_event(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.
