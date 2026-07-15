%% @doc One disposable delegate decision/action round. It starts inert so its
%% coordinator can install the monitor and active-round identity before work.
-module(soma_delegate_round_worker).

-behaviour(gen_statem).

-define(DEFAULT_LLM_TIMEOUT_MS, 60000).
-define(DEFAULT_ACTION_TIMEOUT_MS, 120000).

-export([start_link/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

init(Opts = #{coordinator_pid := CoordinatorPid,
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
    process_flag(trap_exit, true),
    CoordinatorMRef = erlang:monitor(process, CoordinatorPid),
    Data = #{coordinator_pid => CoordinatorPid,
             coordinator_mref => CoordinatorMRef,
             task_id => TaskId,
             correlation_id => CorrelationId,
             round_id => RoundId,
             worker_identity => WorkerIdentity,
             result_capability => ResultCapability,
             snapshot => maps:get(snapshot, Opts, #{}),
             work => Work,
             active_llm => undefined,
             active_run => undefined},
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
    start_llm_call(Data);
handle_event(info,
             {delegate_round_cancel, TaskId, RoundId, WorkerIdentity,
              ResultCapability, Status},
             awaiting_start,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability})
  when Status =:= cancelled; Status =:= timeout ->
    report_round_result(
      Data, #{status => Status, phase => decision});
handle_event(info,
             {delegate_round_cancel, TaskId, RoundId, WorkerIdentity,
              ResultCapability, Status},
             waiting_llm,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability,
                      active_llm := ActiveLlm})
  when Status =:= cancelled; Status =:= timeout ->
    stop_llm_child(ActiveLlm),
    report_round_result(
      Data#{active_llm := undefined},
      #{status => Status, phase => llm});
handle_event(info,
             {delegate_round_cancel, TaskId, RoundId, WorkerIdentity,
              ResultCapability, Status},
             waiting_run,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability,
                      active_run := ActiveRun})
  when Status =:= cancelled; Status =:= timeout ->
    request_run_cancel(Status, ActiveRun, Data);
handle_event(info,
             {llm_result, LlmCallId, LlmPid, {ok, _FixedResult}},
             waiting_llm,
             Data = #{active_llm :=
                          ActiveLlm =
                              #{llm_call_id := LlmCallId,
                                pid := LlmPid,
                                mref := LlmMRef}}) ->
    cancel_child_timer(ActiveLlm),
    release_child_monitor(LlmPid, LlmMRef),
    start_action(Data#{active_llm := undefined});
handle_event(info,
             {llm_result, LlmCallId, LlmPid, {error, Reason}},
             waiting_llm,
             Data = #{active_llm :=
                          ActiveLlm =
                              #{llm_call_id := LlmCallId,
                                pid := LlmPid,
                                mref := LlmMRef}}) ->
    cancel_child_timer(ActiveLlm),
    release_child_monitor(LlmPid, LlmMRef),
    report_round_result(
      Data#{active_llm := undefined},
      #{status => failed, phase => llm, reason => Reason});
handle_event(info,
             {'DOWN', LlmMRef, process, LlmPid, Reason},
             waiting_llm,
             Data = #{active_llm :=
                          ActiveLlm =
                              #{pid := LlmPid, mref := LlmMRef}}) ->
    cancel_child_timer(ActiveLlm),
    report_round_result(
      Data#{active_llm := undefined},
      #{status => failed, phase => llm, reason => Reason});
handle_event(info,
             {timeout, TimerRef,
              {delegate_phase_timeout, llm, LlmCallId}},
             waiting_llm,
             Data = #{active_llm :=
                          ActiveLlm =
                              #{llm_call_id := LlmCallId,
                                timer_ref := TimerRef}}) ->
    stop_llm_child(ActiveLlm),
    report_round_result(
      Data#{active_llm := undefined},
      #{status => timeout, phase => llm});
handle_event(info,
             {run_completed, RunId, Outputs},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun =
                              #{run_id := RunId},
                      work := Work}) ->
    %% A requested cancel (deadline or explicit) is sticky: a run success
    %% racing in before the cancel took effect must not win back the round.
    case maps:get(cancel_status, ActiveRun, undefined) of
        undefined ->
            finish_run_child(ActiveRun),
            report_round_result(
              Data#{active_run := undefined},
              #{status => succeeded,
                phase => action,
                decision => maps:get(decision, Work, terminal),
                terminal_result =>
                    #{status => succeeded, outputs => Outputs}});
        PendingStatus ->
            finish_run_child(ActiveRun),
            report_round_result(
              Data#{active_run := undefined},
              #{status => PendingStatus, phase => action})
    end;
handle_event(info,
             {run_failed, RunId, Reason},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun = #{run_id := RunId}}) ->
    finish_run_child(ActiveRun),
    case maps:get(cancel_status, ActiveRun, undefined) of
        undefined ->
            report_round_result(
              Data#{active_run := undefined},
              #{status => failed, phase => action, reason => Reason});
        PendingStatus ->
            report_round_result(
              Data#{active_run := undefined},
              #{status => PendingStatus, phase => action})
    end;
handle_event(info,
             {run_timeout, RunId},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun = #{run_id := RunId}}) ->
    finish_run_child(ActiveRun),
    report_round_result(
      Data#{active_run := undefined},
      #{status => timeout, phase => action});
handle_event(info,
             {run_cancelled, RunId},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun = #{run_id := RunId}}) ->
    Status = maps:get(cancel_status, ActiveRun, cancelled),
    finish_run_child(ActiveRun),
    report_round_result(
      Data#{active_run := undefined},
      #{status => Status, phase => action});
handle_event(info,
             {'DOWN', RunMRef, process, RunPid, Reason},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun =
                              #{pid := RunPid, mref := RunMRef}}) ->
    cancel_child_timer(ActiveRun),
    report_round_result(
      Data#{active_run := undefined},
      #{status => failed, phase => action, reason => Reason});
handle_event(info,
             {timeout, TimerRef,
              {delegate_phase_timeout, action, RunId}},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun = #{run_id := RunId,
                                        timer_ref := TimerRef}}) ->
    request_run_cancel(timeout, ActiveRun, Data);
handle_event(info,
             {'DOWN', CoordinatorMRef, process, CoordinatorPid, _Reason},
             _StateName,
             Data = #{coordinator_pid := CoordinatorPid,
                      coordinator_mref := CoordinatorMRef}) ->
    stop_active_child(Data),
    {stop, normal, Data};
handle_event(info, {'EXIT', _ChildPid, _Reason}, _StateName, Data) ->
    {keep_state, Data};
handle_event(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.

terminate(_Reason, _StateName, Data) ->
    stop_active_child(Data),
    ok.

start_llm_call(Data = #{work := Work, round_id := RoundId}) ->
    case maps:get(llm, Work, undefined) of
        Llm when is_map(Llm) ->
            LlmCallId = mint_llm_call_id(RoundId),
            LlmOpts = #{owner => self(),
                        llm_call_id => LlmCallId,
                        llm => Llm},
            case soma_llm_call:start_owned(LlmOpts) of
                {ok, LlmPid, LlmMRef} ->
                    TimerRef = arm_phase_timer(
                                 llm, LlmCallId,
                                 maps:get(timeout_ms, Llm, undefined),
                                 ?DEFAULT_LLM_TIMEOUT_MS),
                    ActiveLlm = #{llm_call_id => LlmCallId,
                                  pid => LlmPid,
                                  mref => LlmMRef,
                                  timer_ref => TimerRef},
                    {next_state, waiting_llm,
                     Data#{active_llm := ActiveLlm}};
                {error, Reason} ->
                    report_round_result(
                      Data,
                      #{status => failed,
                        phase => llm,
                        reason => {llm_start_failed, Reason}})
            end;
        _InvalidLlm ->
            report_round_result(
              Data,
              #{status => failed, phase => llm, reason => invalid_llm})
    end.

start_action(Data = #{work := Work}) ->
    case maps:get(action_steps, Work, undefined) of
        Steps when is_list(Steps) ->
            case canonical_steps(Steps) of
                true ->
                    start_run(Steps, Data);
                false ->
                    report_round_result(
                      Data,
                      #{status => failed,
                        phase => action,
                        reason => invalid_action_steps})
            end;
        undefined ->
            report_round_result(
              Data,
              #{status => succeeded,
                phase => decision,
                decision => maps:get(decision, Work, terminal),
                terminal_result => #{status => succeeded}});
        _InvalidSteps ->
            report_round_result(
              Data,
              #{status => failed,
                phase => action,
                reason => invalid_action_steps})
    end.

start_run(Steps,
          Data = #{task_id := TaskId,
                   correlation_id := CorrelationId,
                   work := Work}) ->
    RunId = mint_run_id(),
    report_unsafe_dispatch(Steps, RunId, Data),
    RunOpts = #{run_id => RunId,
                task_id => TaskId,
                session_id => TaskId,
                session_pid => self(),
                correlation_id => CorrelationId,
                event_store => event_store_pid(),
                steps => Steps,
                auto_resume => false},
    case soma_run_sup:start_run(RunOpts) of
        {ok, RunPid} ->
            link(RunPid),
            RunMRef = erlang:monitor(process, RunPid),
            TimerRef = arm_phase_timer(
                         action, RunId,
                         maps:get(action_timeout_ms, Work, undefined),
                         ?DEFAULT_ACTION_TIMEOUT_MS),
            ActiveRun = #{run_id => RunId,
                          pid => RunPid,
                          mref => RunMRef,
                          timer_ref => TimerRef,
                          cancel_status => undefined},
            {next_state, waiting_run,
             Data#{active_run := ActiveRun}};
        {error, Reason} ->
            report_round_result(
              Data,
              #{status => failed,
                phase => action,
                reason => {run_start_failed, Reason}})
    end.

report_round_result(
  Data = #{coordinator_pid := CoordinatorPid,
           task_id := TaskId,
           round_id := RoundId,
           worker_identity := WorkerIdentity,
           result_capability := ResultCapability},
  Result) ->
    CoordinatorPid !
        {delegate_round_result, TaskId, RoundId, self(), WorkerIdentity,
         ResultCapability, Result},
    {stop, normal, Data}.

canonical_steps(Steps) ->
    lists:all(fun canonical_step/1, Steps).

canonical_step(#{id := _StepId, tool := _ToolName} = Step) ->
    is_map(maps:get(args, Step, #{})) andalso
        valid_timeout(maps:get(timeout_ms, Step, undefined));
canonical_step(_Step) ->
    false.

valid_timeout(undefined) ->
    true;
valid_timeout(TimeoutMs) ->
    is_integer(TimeoutMs) andalso TimeoutMs > 0.

report_unsafe_dispatch(Steps, RunId,
                       #{coordinator_pid := CoordinatorPid,
                         task_id := TaskId,
                         round_id := RoundId,
                         worker_identity := WorkerIdentity,
                         result_capability := ResultCapability}) ->
    case first_unsafe_invocation(Steps, RunId) of
        none ->
            ok;
        InvocationIdentity ->
            CoordinatorPid !
                {delegate_unsafe_action_dispatched,
                 TaskId, RoundId, self(), WorkerIdentity,
                 ResultCapability, InvocationIdentity},
            ok
    end.

first_unsafe_invocation([], _RunId) ->
    none;
first_unsafe_invocation(
  [#{id := StepId, tool := ToolName} = Step | Remaining], RunId) ->
    case step_repeat_safe(Step) of
        true ->
            first_unsafe_invocation(Remaining, RunId);
        false ->
            #{run_id => RunId, step_id => StepId, tool => ToolName}
    end.

step_repeat_safe(#{tool := ToolName}) ->
    case soma_tool_registry:resolve_descriptor(ToolName) of
        {ok, Descriptor} ->
            soma_run_resume_safety:descriptor_safe(Descriptor);
        {error, not_found} ->
            false
    end.

release_child_monitor(Pid, MRef) ->
    _ = erlang:demonitor(MRef, [flush]),
    unlink(Pid),
    ok.

finish_run_child(ActiveRun = #{pid := RunPid, mref := RunMRef}) ->
    cancel_child_timer(ActiveRun),
    remove_run_child(RunPid, RunMRef).

remove_run_child(RunPid, RunMRef) ->
    release_child_monitor(RunPid, RunMRef),
    _ = supervisor:terminate_child(soma_run_sup, RunPid),
    ok.

stop_active_child(#{active_llm := ActiveLlm})
  when is_map(ActiveLlm) ->
    stop_llm_child(ActiveLlm);
stop_active_child(#{active_run := ActiveRun})
  when is_map(ActiveRun) ->
    finish_run_child(ActiveRun);
stop_active_child(_Data) ->
    ok.

stop_llm_child(ActiveLlm = #{pid := LlmPid, mref := LlmMRef}) ->
    cancel_child_timer(ActiveLlm),
    exit(LlmPid, kill),
    await_child_down(LlmMRef, LlmPid),
    unlink(LlmPid),
    ok.

request_run_cancel(Status, ActiveRun = #{pid := RunPid}, Data) ->
    cancel_child_timer(ActiveRun),
    RunPid ! cancel,
    UpdatedRun = ActiveRun#{timer_ref := undefined,
                            cancel_status := Status},
    {keep_state, Data#{active_run := UpdatedRun}}.

arm_phase_timer(Phase, ChildId, ConfiguredTimeout, DefaultTimeout) ->
    TimeoutMs = timeout_ms(ConfiguredTimeout, DefaultTimeout),
    erlang:start_timer(
      TimeoutMs, self(),
      {delegate_phase_timeout, Phase, ChildId}).

timeout_ms(TimeoutMs, _Default)
  when is_integer(TimeoutMs), TimeoutMs > 0 ->
    TimeoutMs;
timeout_ms(_InvalidOrMissing, Default) ->
    Default.

cancel_child_timer(ActiveChild) ->
    cancel_timer(maps:get(timer_ref, ActiveChild, undefined)).

cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) when is_reference(TimerRef) ->
    _ = erlang:cancel_timer(
          TimerRef, [{async, false}, {info, false}]),
    ok.

await_child_down(MRef, ChildPid) ->
    receive
        {'DOWN', MRef, process, ChildPid, _Reason} ->
            ok
    after 1000 ->
        _ = erlang:demonitor(MRef, [flush]),
        ok
    end.

mint_llm_call_id(RoundId) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<"delegate-llm-", (integer_to_binary(RoundId))/binary,
      "-", Suffix/binary>>.

mint_run_id() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<"delegate-run-", Suffix/binary>>.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
