%% @doc One disposable delegate decision/action round. It starts inert so its
%% coordinator can install the monitor and active-round identity before work.
-module(soma_delegate_round_worker).

-behaviour(gen_statem).

-define(DEFAULT_LLM_TIMEOUT_MS, 60000).
-define(DEFAULT_ACTION_TIMEOUT_MS, 120000).
-define(DEFAULT_MAX_OBSERVATION_BYTES, 16384).
-define(MAX_INLINE_OBSERVATION_BYTES, 4096).

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
             tool_policy =>
                 maps:get(tool_policy, Opts, #{allowed_tools => []}),
             capability_scope =>
                 maps:get(capability_scope, Opts, #{tools => []}),
             snapshot => maps:get(snapshot, Opts, #{}),
             work => Work,
             adaptive_mode => model_selects_proposal(Work),
             pending_budget => undefined,
             pending_run => undefined,
             provider_usage => undefined,
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
             StateName,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability})
  when (StateName =:= waiting_llm_budget orelse
        StateName =:= waiting_tool_budget orelse
        StateName =:= waiting_unsafe_dispatch),
       (Status =:= cancelled orelse Status =:= timeout) ->
    Phase =
        case StateName of
            waiting_llm_budget -> llm;
            waiting_tool_budget -> action;
            waiting_unsafe_dispatch -> action
        end,
    report_round_result(
      Data#{pending_budget := undefined, pending_run := undefined},
      #{status => Status, phase => Phase});
handle_event(info,
             {delegate_budget_reserved,
              TaskId, RoundId, WorkerIdentity, ResultCapability,
              llm_calls, ok},
             waiting_llm_budget,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability,
                      pending_budget :=
                          #{operation := {llm, Llm}}}) ->
    start_reserved_llm_call(
      Llm, RoundId, Data#{pending_budget := undefined});
handle_event(info,
             {delegate_budget_reserved,
              TaskId, RoundId, WorkerIdentity, ResultCapability,
              llm_calls, {error, Reason}},
             waiting_llm_budget,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability}) ->
    report_round_result(
      Data#{pending_budget := undefined},
      #{status => failed, phase => llm, reason => Reason});
handle_event(info,
             {delegate_budget_reserved,
              TaskId, RoundId, WorkerIdentity, ResultCapability,
              tool_calls, ok},
             waiting_tool_budget,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability,
                      pending_budget :=
                          #{operation := {run, Steps}}}) ->
    start_reserved_run(
      Steps, Data#{pending_budget := undefined});
handle_event(info,
             {delegate_unsafe_action_recorded,
              TaskId, RoundId, WorkerIdentity, ResultCapability,
              UnsafeInvocations},
             waiting_unsafe_dispatch,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability,
                      pending_run :=
                          #{steps := Steps,
                            run_id := RunId,
                            unsafe_invocations := UnsafeInvocations}}) ->
    launch_reserved_run(
      Steps, RunId, UnsafeInvocations,
      Data#{pending_run := undefined});
handle_event(info,
             {delegate_budget_reserved,
              TaskId, RoundId, WorkerIdentity, ResultCapability,
              tool_calls, {error, Reason}},
             waiting_tool_budget,
             Data = #{task_id := TaskId,
                      round_id := RoundId,
                      worker_identity := WorkerIdentity,
                      result_capability := ResultCapability}) ->
    report_round_result(
      Data#{pending_budget := undefined},
      #{status => failed, phase => action, reason => Reason});
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
             {llm_result, LlmCallId, LlmPid, {ok, ModelResult}},
             waiting_llm,
             Data = #{active_llm :=
                          ActiveLlm =
                              #{llm_call_id := LlmCallId,
                                pid := LlmPid,
                                mref := LlmMRef}}) ->
    cancel_child_timer(ActiveLlm),
    release_child_monitor(LlmPid, LlmMRef),
    {ProposalResult, ProviderUsage} =
        take_provider_usage(ModelResult, Data),
    handle_successful_model_result(
      ProposalResult,
      Data#{active_llm := undefined,
            provider_usage := ProviderUsage});
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
            case completed_action_observation(Outputs, Data) of
                {ok, ObservationFields} ->
                    Result0 =
                        maps:merge(
                          #{status => succeeded,
                            phase => action,
                            decision =>
                                maps:get(decision, Work, terminal)},
                          ObservationFields),
                    Result1 =
                        maybe_add_adaptive_safety(
                          ActiveRun, Data, Result0),
                    report_round_result(
                      Data#{active_run := undefined},
                      maybe_add_adaptive_run_id(
                        ActiveRun, Data, Result1));
                {error, Reason} ->
                    report_round_result(
                      Data#{active_run := undefined},
                      #{status => failed,
                        phase => action,
                        reason => Reason})
            end;
        PendingStatus ->
            finish_run_child(ActiveRun),
            report_round_result(
              Data#{active_run := undefined},
              maybe_add_adaptive_run_id(
                ActiveRun, Data,
                maybe_add_adaptive_safety(
                  ActiveRun, Data,
                  #{status => PendingStatus, phase => action})))
    end;
handle_event(info,
             {run_failed, RunId, Reason},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun = #{run_id := RunId}}) ->
    finish_run_child(ActiveRun),
    case maps:get(cancel_status, ActiveRun, undefined) of
        undefined ->
            Result = known_action_failure_result(Reason, ActiveRun, Data),
            report_round_result(
              Data#{active_run := undefined},
              Result);
        PendingStatus ->
            report_round_result(
              Data#{active_run := undefined},
              maybe_add_adaptive_run_id(
                ActiveRun, Data,
                maybe_add_adaptive_safety(
                  ActiveRun, Data,
                  #{status => PendingStatus, phase => action})))
    end;
handle_event(info,
             {run_timeout, RunId},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun = #{run_id := RunId}}) ->
    finish_run_child(ActiveRun),
    Result = known_action_timeout_result(ActiveRun, Data),
    report_round_result(
      Data#{active_run := undefined},
      Result);
handle_event(info,
             {run_cancelled, RunId},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun = #{run_id := RunId}}) ->
    Status = maps:get(cancel_status, ActiveRun, cancelled),
    finish_run_child(ActiveRun),
    report_round_result(
      Data#{active_run := undefined},
      maybe_add_adaptive_run_id(
        ActiveRun, Data,
        maybe_add_adaptive_safety(
          ActiveRun, Data,
          #{status => Status, phase => action})));
handle_event(info,
             {'DOWN', RunMRef, process, RunPid, Reason},
             waiting_run,
             Data = #{active_run :=
                          ActiveRun =
                              #{pid := RunPid, mref := RunMRef}}) ->
    cancel_child_timer(ActiveRun),
    report_round_result(
      Data#{active_run := undefined},
      maybe_add_adaptive_run_id(
        ActiveRun, Data,
        maybe_add_adaptive_safety(
          ActiveRun, Data,
          #{status => failed, phase => action, reason => Reason})));
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

start_llm_call(Data = #{work := Work}) ->
    case maps:get(llm, Work, undefined) of
        Llm when is_map(Llm) ->
            request_budget(
              llm_calls, 1, {llm, Llm}, waiting_llm_budget, Data);
        _InvalidLlm ->
            report_round_result(
              Data,
              #{status => failed, phase => llm, reason => invalid_llm})
    end.

start_reserved_llm_call(Llm, RoundId, Data) ->
    LlmCallId = mint_llm_call_id(RoundId),
    LlmOpts = #{owner => self(),
                llm_call_id => LlmCallId,
                llm => Llm},
    %% start_owned spawns and monitors; it has no failure return.
    {ok, LlmPid, LlmMRef} = soma_llm_call:start_owned(LlmOpts),
    TimerRef = arm_phase_timer(
                 llm, LlmCallId,
                 maps:get(timeout_ms, Llm, undefined),
                 ?DEFAULT_LLM_TIMEOUT_MS),
    ActiveLlm = #{llm_call_id => LlmCallId,
                  pid => LlmPid,
                  mref => LlmMRef,
                  timer_ref => TimerRef},
    {next_state, waiting_llm,
     Data#{active_llm := ActiveLlm}}.

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

handle_successful_model_result(ModelResult, Data = #{work := Work}) ->
    case maps:is_key(action_steps, Work) orelse
         not model_selects_proposal(Work) of
        true ->
            start_action(Data);
        false ->
            admit_model_result(ModelResult, Data)
    end.

model_selects_proposal(#{llm := #{provider := openai_compat}}) ->
    true;
model_selects_proposal(#{llm := #{directive := proposal}}) ->
    true;
model_selects_proposal(_LegacyRoundWork) ->
    false.

admit_model_result(ModelResult, Data) ->
    case decode_model_result(ModelResult, Data) of
        {ok, RawProposal} ->
            admit_raw_proposal(RawProposal, Data);
        {error, Reason} ->
            ok = emit_adaptive_decision(
                   #{kind => invalid}, not_evaluated,
                   not_evaluated, Data),
            report_round_result(
              Data,
              #{status => failed,
                phase => decision,
                reason => Reason})
    end.

admit_raw_proposal(RawProposal,
                   Data = #{tool_policy := ToolPolicy,
                            capability_scope := CapabilityScope}) ->
    case soma_proposal:normalize(RawProposal) of
        {ok, Proposal} ->
            case soma_policy:check(Proposal, ToolPolicy) of
                allow ->
                    case soma_delegate_capability:check(
                           Proposal, CapabilityScope) of
                        allow ->
                            ok = emit_adaptive_decision(
                                   Proposal, allow, allow, Data),
                            execute_admitted_proposal(Proposal, Data);
                        {reject, Reason} ->
                            ok = emit_adaptive_decision(
                                   Proposal, allow, reject, Data),
                            report_admission_rejection(
                              task_capability, Reason, Data)
                    end;
                {reject, Reason} ->
                    ok = emit_adaptive_decision(
                           Proposal, reject, not_evaluated, Data),
                    report_admission_rejection(
                      global_policy, Reason, Data)
            end;
        {error, Diagnostics} ->
            ok = emit_adaptive_decision(
                   #{kind => invalid}, not_evaluated,
                   not_evaluated, Data),
            report_round_result(
              Data,
              #{status => failed,
                phase => decision,
                reason => {invalid_proposal, Diagnostics}})
    end.

execute_admitted_proposal(
  #{kind := run_steps, steps := Steps},
  Data = #{work := Work}) ->
    %% In delegate mode an admitted action is an observation-producing turn,
    %% never the terminal answer. The coordinator decides whether another
    %% configured model round remains after it commits the run result.
    start_run(
      Steps,
      Data#{work := Work#{decision => continue,
                          adaptive_action => true}});
execute_admitted_proposal(#{kind := reply, text := Text}, Data) ->
    report_round_result(
      Data,
      #{status => succeeded,
        phase => decision,
        decision => terminal,
        terminal_result => #{status => succeeded, result => Text}});
execute_admitted_proposal(#{kind := reject, reason := Reason}, Data) ->
    report_round_result(
      Data,
      #{status => rejected,
        phase => decision,
        reason => {model_rejected, Reason}}).

report_admission_rejection(Gate, Reason, Data) ->
    report_round_result(
      Data,
      #{status => rejected,
        phase => decision,
        reason => {admission_rejected, Gate, Reason}}).

decode_model_result(
  #{kind := reply, text := Content} = ProviderReply,
  #{work := #{llm := #{provider := openai_compat}}}) ->
    case starts_lisp_form(Content) of
        true -> compile_proposal(Content);
        false -> {ok, ProviderReply}
    end;
decode_model_result(RawProposal, _Data) when is_map(RawProposal) ->
    {ok, RawProposal};
decode_model_result(Source, _Data)
  when is_binary(Source); is_list(Source) ->
    compile_proposal(Source);
decode_model_result(_InvalidModelResult, _Data) ->
    {error, invalid_model_result}.

compile_proposal(Source) ->
    case soma_lfe:compile(Source, #{existing_atoms_only => true}) of
        {ok, ProposalMap} ->
            {ok, ProposalMap};
        {error, Diagnostics} ->
            {error, {invalid_proposal_source, Diagnostics}}
    end.

starts_lisp_form(Content) when is_binary(Content) ->
    case string:trim(Content, leading) of
        <<$(, _/binary>> -> true;
        _PlainText -> false
    end;
starts_lisp_form(Content) when is_list(Content) ->
    try unicode:characters_to_binary(Content) of
        Binary when is_binary(Binary) -> starts_lisp_form(Binary);
        _InvalidText -> false
    catch
        error:badarg -> false
    end;
starts_lisp_form(_OtherContent) ->
    false.

start_run(Steps,
          Data) ->
    request_budget(
      tool_calls, length(Steps), {run, Steps},
      waiting_tool_budget, Data).

start_reserved_run(
  Steps,
  Data) ->
    RunId = mint_run_id(),
    UnsafeInvocations = unsafe_invocations(Steps, RunId),
    case UnsafeInvocations of
        [] ->
            launch_reserved_run(Steps, RunId, [], Data);
        [_Unsafe | _] ->
            report_unsafe_dispatch(UnsafeInvocations, Data),
            PendingRun = #{steps => Steps,
                           run_id => RunId,
                           unsafe_invocations => UnsafeInvocations},
            {next_state, waiting_unsafe_dispatch,
             Data#{pending_run := PendingRun}}
    end.

launch_reserved_run(
  Steps, RunId, UnsafeInvocations,
  Data = #{task_id := TaskId,
           correlation_id := CorrelationId,
           work := Work}) ->
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
                          cancel_status => undefined,
                          unsafe_invocations => UnsafeInvocations},
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
    ReportedResult0 = maybe_attach_provider_usage(Result, Data),
    ReportedResult = maybe_attach_adaptive_event(ReportedResult0, Data),
    CoordinatorPid !
        {delegate_round_result, TaskId, RoundId, self(), WorkerIdentity,
         ResultCapability, ReportedResult},
    {stop, normal, Data}.

take_provider_usage(
  ModelResult = #{usage := Usage = #{prompt_tokens := PromptTokens}},
  #{work := #{llm := #{provider := openai_compat,
                        retain_usage := true}}})
  when is_integer(PromptTokens), PromptTokens >= 0 ->
    {maps:remove(usage, ModelResult),
     maps:with([prompt_tokens], Usage)};
take_provider_usage(ModelResult, _Data) ->
    {ModelResult, undefined}.

maybe_attach_provider_usage(
  Result, #{provider_usage := Usage}) when is_map(Usage) ->
    Result#{usage => Usage};
maybe_attach_provider_usage(Result, _Data) ->
    Result.

maybe_attach_adaptive_event(
  Result, #{adaptive_mode := true}) ->
    Result#{adaptive_event => true};
maybe_attach_adaptive_event(Result, _Data) ->
    Result.

request_budget(
  Counter, Units, Operation, WaitingState,
  Data = #{coordinator_pid := CoordinatorPid,
           task_id := TaskId,
           round_id := RoundId,
           worker_identity := WorkerIdentity,
           result_capability := ResultCapability}) ->
    CoordinatorPid !
        {delegate_reserve_budget,
         TaskId, RoundId, self(), WorkerIdentity, ResultCapability,
         Counter, Units},
    PendingBudget = #{counter => Counter,
                      units => Units,
                      operation => Operation},
    {next_state, WaitingState,
     Data#{pending_budget := PendingBudget}}.

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

report_unsafe_dispatch([], _Data) ->
    ok;
report_unsafe_dispatch(
  UnsafeInvocations,
  #{coordinator_pid := CoordinatorPid,
    task_id := TaskId,
    round_id := RoundId,
    worker_identity := WorkerIdentity,
    result_capability := ResultCapability})
  when is_list(UnsafeInvocations), UnsafeInvocations =/= [] ->
    CoordinatorPid !
        {delegate_unsafe_action_dispatched,
         TaskId, RoundId, self(), WorkerIdentity,
         ResultCapability, UnsafeInvocations},
    ok.

known_action_failure_result(Reason, ActiveRun, Data) ->
    case adaptive_action(Data) of
        true ->
            Result0 =
                #{status => failed,
                  phase => action,
                  decision => continue,
                  terminal_result =>
                      bounded_failure_observation(Reason, Data)},
            maybe_add_adaptive_run_id(
              ActiveRun, Data,
              maybe_add_adaptive_safety(
                ActiveRun, Data, Result0));
        false ->
            #{status => failed, phase => action, reason => Reason}
    end.

known_action_timeout_result(ActiveRun, Data) ->
    case adaptive_action(Data) of
        true ->
            Result0 =
                #{status => timeout,
                  phase => action,
                  decision => continue,
                  terminal_result => #{status => timeout}},
            maybe_add_adaptive_run_id(
              ActiveRun, Data,
              maybe_add_adaptive_safety(
                ActiveRun, Data, Result0));
        false ->
            #{status => timeout, phase => action}
    end.

maybe_add_adaptive_safety(
  #{unsafe_invocations := UnsafeInvocations},
  #{round_id := RoundId} = Data,
  Result)
  when is_list(UnsafeInvocations), UnsafeInvocations =/= [] ->
    case adaptive_action(Data) of
        true ->
            Facts =
                soma_delegate_safety:facts(
                  UnsafeInvocations, RoundId, event_store_pid()),
            attach_safety_facts(Facts, Result);
        false ->
            Result
    end;
maybe_add_adaptive_safety(_ActiveRun, _Data, Result) ->
    Result.

attach_safety_facts(
  #{mutations := Mutations, unknown_outcomes := UnknownOutcomes},
  Result) ->
    MutationResult =
        case Mutations of
            [] -> Result;
            [_Mutation | _] -> Result#{mutations => Mutations}
        end,
    case UnknownOutcomes of
        [] -> MutationResult;
        [_Unknown | _] ->
            MutationResult#{unknown_outcomes => UnknownOutcomes}
    end.

maybe_add_adaptive_run_id(
  #{run_id := RunId}, Data, Result) ->
    case adaptive_action(Data) of
        true -> Result#{run_id => RunId};
        false -> Result
    end.

adaptive_action(#{work := Work}) ->
    maps:get(adaptive_action, Work, false).

emit_adaptive_decision(
  Proposal, GlobalPolicyVerdict, TaskCapabilityVerdict,
  Data = #{task_id := TaskId,
           correlation_id := CorrelationId,
           round_id := RoundId}) ->
    Outcome =
        Data#{action_summary => adaptive_action_summary(Proposal),
              global_policy_verdict => GlobalPolicyVerdict,
              task_capability_verdict => TaskCapabilityVerdict},
    soma_delegate_event:append(
      <<"delegate.decision.completed">>, TaskId,
      CorrelationId, RoundId, Outcome).

adaptive_action_summary(#{kind := run_steps, steps := Steps})
  when is_list(Steps) ->
    #{kind => run_steps, step_count => length(Steps)};
adaptive_action_summary(#{kind := Kind})
  when Kind =:= reply; Kind =:= reject; Kind =:= ask;
       Kind =:= actor_message; Kind =:= invalid ->
    #{kind => Kind};
adaptive_action_summary(_InvalidProposal) ->
    #{kind => invalid}.

completed_action_observation(Outputs, Data = #{task_id := TaskId}) ->
    Observation = #{status => succeeded, outputs => Outputs},
    CompleteBytes =
        iolist_to_binary(soma_lisp:render(Observation)),
    MaxBytes = observation_envelope_bytes(Data),
    case adaptive_action(Data) andalso
         byte_size(CompleteBytes) > MaxBytes of
        true ->
            case soma_delegate_artifact_store:put(TaskId, CompleteBytes) of
                {ok, Artifact = #{handle := Handle}} ->
                    Excerpt =
                        soma_delegate_prompt:artifact_excerpt(
                          Artifact, CompleteBytes, MaxBytes),
                    {ok, #{terminal_result => #{handle => Handle},
                           artifact => Artifact,
                           artifact_excerpt => Excerpt}};
                {error, _StoreReason} ->
                    {error, artifact_store_failed}
            end;
        false ->
            {ok, #{terminal_result => Observation}}
    end.

bounded_failure_observation(Reason, Data) ->
    MaxBytes = observation_envelope_bytes(Data),
    Serialized = iolist_to_binary(soma_lisp:render(Reason)),
    RetainedBytes = min(byte_size(Serialized), MaxBytes),
    Retained = binary:part(Serialized, 0, RetainedBytes),
    Base = #{status => failed, reason => Retained},
    case byte_size(Serialized) > MaxBytes of
        true -> Base#{truncated => true};
        false -> Base
    end.

observation_envelope_bytes(Data) ->
    min(max_observation_bytes(Data), ?MAX_INLINE_OBSERVATION_BYTES).

max_observation_bytes(#{snapshot := Snapshot}) ->
    Budgets = maps:get(budgets, Snapshot, #{}),
    case maps:get(max_observation_bytes, Budgets,
                  ?DEFAULT_MAX_OBSERVATION_BYTES) of
        MaxBytes when is_integer(MaxBytes), MaxBytes > 0 ->
            MaxBytes;
        _InvalidMaxBytes ->
            ?DEFAULT_MAX_OBSERVATION_BYTES
    end.

unsafe_invocations(Steps, RunId) ->
    unsafe_invocations(Steps, RunId, []).

unsafe_invocations([], _RunId, Acc) ->
    lists:reverse(Acc);
unsafe_invocations(
  [#{id := StepId, tool := ToolName} = Step | Remaining], RunId, Acc) ->
    case step_repeat_safe(Step) of
        true ->
            unsafe_invocations(Remaining, RunId, Acc);
        false ->
            Invocation =
                #{invocation_id => mint_invocation_id(),
                  run_id => RunId,
                  step_id => StepId,
                  tool => ToolName},
            unsafe_invocations(Remaining, RunId, [Invocation | Acc])
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

mint_invocation_id() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<"delegate-invocation-", Suffix/binary>>.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
