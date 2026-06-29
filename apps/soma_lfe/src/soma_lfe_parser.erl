%% @doc Walks raw form list from soma_lfe_reader and produces the internal
%% run representation, or a list of structured diagnostics.
-module(soma_lfe_parser).

-export([parse_run/1, parse_task/1, parse_msg/1, parse_proposal/1, parse_ask/1,
         parse_trace/1, parse_status/1, parse_cancel/1, parse_stop/1]).

-type diagnostic() :: #{code => atom(), message => binary(), line => non_neg_integer()}.

%% @doc Parse a single (msg ...) form into an actor envelope map.
-spec parse_msg([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_msg([msg | SubForms]) ->
    parse_msg_fields(SubForms, #{}).

parse_msg_fields([], Acc) ->
    case validate_msg_required(Acc) of
        [] ->
            {ok, Acc};
        Diags ->
            {error, Diags}
    end;
parse_msg_fields([[type, Value] | Rest], Acc) ->
    parse_msg_fields(Rest, Acc#{type => Value});
parse_msg_fields([[payload, Value] | Rest], Acc) ->
    parse_msg_fields(Rest, Acc#{payload => Value});
parse_msg_fields([[steps | StepForms] | Rest], Acc) ->
    case parse_msg_steps(StepForms, []) of
        {ok, Steps} ->
            parse_msg_fields(Rest, Acc#{steps => Steps});
        {error, Diags} ->
            {error, Diags}
    end;
parse_msg_fields([['correlation-id', Value] | Rest], Acc) ->
    parse_msg_fields(Rest, Acc#{correlation_id => Value});
parse_msg_fields([[llm | LlmForms] | Rest], Acc) ->
    case parse_args(LlmForms, #{}) of
        {ok, LlmMap} ->
            parse_msg_fields(Rest, Acc#{llm => LlmMap});
        {error, Diags} ->
            {error, Diags}
    end;
parse_msg_fields([[Head | _] | _], _Acc) when is_atom(Head) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unknown msg sub-form: '~s'", [Head])),
               line => 0}]};
parse_msg_fields([Other | _], _Acc) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unexpected form inside msg: ~p", [Other])),
               line => 0}]}.

%% type and payload are required; report a diagnostic for each missing one.
validate_msg_required(Acc) ->
    [#{code => missing_required_field,
       message => iolist_to_binary(
           io_lib:format("msg is missing required field: '~s'", [Field])),
       line => 0}
     || Field <- [type, payload], not maps:is_key(Field, Acc)].

%% @doc Parse a public (task ...) form into the same canonical run map as
%% the older (run ...) form.
-spec parse_task([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_task([task, ['let*', Bindings, [return, ReturnId]]])
        when is_list(Bindings), is_atom(ReturnId) ->
    case parse_task_bindings(Bindings, [], []) of
        {ok, Steps} ->
            case validate_steps(Steps) ++ validate_task_return(ReturnId, Steps) of
                [] ->
                    {ok, #{run => #{steps => Steps}}};
                Diags ->
                    {error, Diags}
            end;
        {error, Diags} ->
            {error, Diags}
    end;
parse_task([task | _]) ->
    {error, [#{code => malformed_task,
               message => <<"task form must be (task (let* ((id (tool name ...))) (return id)))">>,
               line => 0}]}.

parse_task_bindings([], Acc, []) ->
    {ok, lists:reverse(Acc)};
parse_task_bindings([], _Acc, ErrAcc) ->
    {error, lists:reverse(ErrAcc)};
parse_task_bindings([Binding | Rest], Acc, ErrAcc) ->
    case parse_task_binding(Binding) of
        {ok, Step} ->
            parse_task_bindings(Rest, [Step | Acc], ErrAcc);
        {error, Diags} ->
            parse_task_bindings(Rest, Acc, lists:reverse(Diags) ++ ErrAcc)
    end.

parse_task_binding([Id, [tool, Tool | ArgForms]]) when is_atom(Id), is_atom(Tool) ->
    case parse_task_args(ArgForms, #{}) of
        {ok, Args} ->
            {ok, #{id => Id, tool => Tool, args => Args}};
        {error, Diags} ->
            {error, Diags}
    end;
parse_task_binding(_Other) ->
    {error, [#{code => malformed_task,
               message => <<"task let* bindings must be (id (tool name ...)) pairs">>,
               line => 0}]}.

parse_task_args(ArgForms, Acc) ->
    parse_args(ArgForms, Acc).

validate_task_return(ReturnId, Steps) ->
    case lists:any(fun(Step) -> maps:get(id, Step) =:= ReturnId end, Steps) of
        true ->
            [];
        false ->
            [#{code => invalid_task_return,
               message => iolist_to_binary(
                   io_lib:format("task return references unknown binding: '~s'", [ReturnId])),
               line => 0}]
    end.

parse_msg_steps([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_msg_steps([[step | StepChildren] | Rest], Acc) ->
    case parse_msg_step(StepChildren, #{args => #{}}) of
        {ok, Step} ->
            parse_msg_steps(Rest, [Step | Acc]);
        {error, Diags} ->
            {error, Diags}
    end;
parse_msg_steps([[Head | _] | _], _Acc) when is_atom(Head) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("steps child form must be 'step', got '~s'", [Head])),
               line => 0}]};
parse_msg_steps([Other | _], _Acc) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unexpected form inside steps: ~p", [Other])),
               line => 0}]}.

parse_msg_step([], Acc) ->
    {ok, Acc};
parse_msg_step([[id, Id] | Rest], Acc) ->
    parse_msg_step(Rest, Acc#{id => Id});
parse_msg_step([[tool, Tool] | Rest], Acc) ->
    parse_msg_step(Rest, Acc#{tool => Tool});
parse_msg_step([[args | KVPairs] | Rest], Acc) ->
    case parse_args(KVPairs, #{}) of
        {ok, ArgsMap} ->
            parse_msg_step(Rest, Acc#{args => ArgsMap});
        {error, Diags} ->
            {error, Diags}
    end;
parse_msg_step([[Head | _] | _], _Acc) when is_atom(Head) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unknown step child form: '~s' (expected 'id', 'tool' or 'args')", [Head])),
               line => 0}]};
parse_msg_step([Other | _], _Acc) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unexpected token in step children: ~p", [Other])),
               line => 0}]}.

%% @doc Parse a single proposal form into the #{kind => ...} map
%% soma_proposal:normalize/1 accepts.
-spec parse_proposal([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_proposal([reply, [text, Text]]) when is_binary(Text) ->
    {ok, #{kind => reply, text => Text}};
parse_proposal([reject, [reason, Reason]]) when is_binary(Reason) ->
    {ok, #{kind => reject, reason => Reason}};
parse_proposal(['run-steps' | StepForms]) ->
    %% Reuse the L.1 step parser (parse_msg_steps) so the step maps are
    %% identical to the run path's steps.
    case parse_msg_steps(StepForms, []) of
        {ok, Steps} ->
            {ok, #{kind => run_steps, steps => Steps}};
        {error, Diags} ->
            {error, Diags}
    end;
parse_proposal([Head | _]) when is_atom(Head) ->
    {error, [#{code => malformed_proposal,
               message => iolist_to_binary(
                   io_lib:format("malformed proposal form: '~s'", [Head])),
               line => 0}]};
parse_proposal(Other) ->
    {error, [#{code => malformed_proposal,
               message => iolist_to_binary(
                   io_lib:format("malformed proposal form: ~p", [Other])),
               line => 0}]}.

%% @doc Parse a single (ask ...) form into an ask command map.
%% This slice handles the bare-intent case: a required (intent "...")
%% sub-form holding a string produces #{ask => #{intent => <<"...">>}}.
-spec parse_ask([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_ask([ask | SubForms]) ->
    parse_ask_fields(SubForms, #{}).

parse_ask_fields([], Acc) ->
    case maps:is_key(intent, Acc) of
        true ->
            {ok, #{ask => Acc}};
        false ->
            {error, [#{code => missing_required_field,
                       message => <<"ask is missing required field: 'intent'">>,
                       line => 0}]}
    end;
parse_ask_fields([[intent, Value] | Rest], Acc) when is_binary(Value) ->
    parse_ask_fields(Rest, Acc#{intent => Value});
parse_ask_fields([[allow | Tools] | Rest], Acc) ->
    ToolPolicy = #{allowed_tools => Tools},
    parse_ask_fields(Rest, Acc#{tool_policy => ToolPolicy});
parse_ask_fields([['budget-llm', N] | Rest], Acc) when is_integer(N) ->
    Budget = maps:get(budget, Acc, #{}),
    parse_ask_fields(Rest, Acc#{budget => Budget#{max_llm_calls => N}});
parse_ask_fields([['budget-steps', N] | Rest], Acc) when is_integer(N) ->
    Budget = maps:get(budget, Acc, #{}),
    parse_ask_fields(Rest, Acc#{budget => Budget#{max_steps => N}});
parse_ask_fields([[intent, Value] | _Rest], _Acc) ->
    {error, [#{code => malformed_form,
               message => iolist_to_binary(
                   io_lib:format("ask intent must be a string, got: ~p", [Value])),
               line => 0}]};
parse_ask_fields([Other | _Rest], _Acc) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unknown ask sub-form: ~p", [Other])),
               line => 0}]}.

%% @doc Parse a single (trace "<corr>") form into a trace command map.
%% The required argument is a quoted string holding the correlation id; the
%% top-level key 'trace' is distinct from the run/ask write-path keys so the
%% server can tell the results apart by key alone.
-spec parse_trace([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_trace([trace, CorrId]) when is_binary(CorrId) ->
    {ok, #{trace => #{correlation_id => CorrId}}};
parse_trace(_Other) ->
    {error, [#{code => malformed_form,
               message => <<"trace requires a single string argument: (trace \"<correlation-id>\")">>,
               line => 0}]}.

-spec parse_status([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_status([status, TaskId]) when is_binary(TaskId) ->
    {ok, #{status => #{task_id => TaskId}}};
parse_status(_Other) ->
    {error, [#{code => malformed_form,
               message => <<"status requires a single string argument: (status \"<task-id>\")">>,
               line => 0}]}.

-spec parse_cancel([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_cancel([cancel, TaskId]) when is_binary(TaskId) ->
    {ok, #{cancel => #{task_id => TaskId}}};
parse_cancel(_Other) ->
    {error, [#{code => malformed_form,
               message => <<"cancel requires a single string argument: (cancel \"<task-id>\")">>,
               line => 0}]}.

%% @doc Parse a bare (stop) form into a stop command map. The daemon parses
%% the request in-band over the Lisp wire — no Erlang distribution, relx rpc,
%% or OS signal. Extra tokens are rejected.
-spec parse_stop([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_stop([stop]) ->
    {ok, #{stop => #{}}};
parse_stop(_Other) ->
    {error, [#{code => malformed_form,
               message => <<"stop takes no arguments: (stop)">>,
               line => 0}]}.

-spec parse_run([term()]) ->
    {ok, #{run => #{steps := [map()], detach => true}}}
    | {error, [diagnostic()]}.
parse_run([]) ->
    {error, [#{code => missing_run_form,
               message => <<"expected exactly one top-level form, got none">>,
               line => 0}]};
parse_run([_Form1, _Form2 | _]) ->
    {error, [#{code => multiple_run_forms,
               message => <<"expected exactly one top-level form, got multiple">>,
               line => 0}]};
parse_run([[run | ChildForms]]) ->
    {StepForms, Detached} = extract_run_detach(ChildForms, [], false),
    case parse_steps(StepForms, [], []) of
        {ok, Steps} ->
            case validate_steps(Steps) of
                [] ->
                    {ok, #{run => maybe_detached_run(#{steps => Steps}, Detached)}};
                Diags ->
                    {error, Diags}
            end;
        {error, Diags} ->
            {error, Diags}
    end;
parse_run([[Head | _]]) when is_atom(Head) ->
    {error, [#{code => invalid_top_level_form,
               message => iolist_to_binary(
                   io_lib:format("top-level form must be 'run', got '~s'", [Head])),
               line => 0}]};
parse_run([Form]) when is_list(Form) ->
    {error, [#{code => invalid_top_level_form,
               message => <<"top-level form must be a list headed by 'run'">>,
               line => 0}]};
parse_run([_Form]) ->
    {error, [#{code => invalid_top_level_form,
               message => <<"top-level form must be a list headed by 'run'">>,
               line => 0}]}.

extract_run_detach([], Acc, Detached) ->
    {lists:reverse(Acc), Detached};
extract_run_detach([[detach] | Rest], Acc, _Detached) ->
    extract_run_detach(Rest, Acc, true);
extract_run_detach([Form | Rest], Acc, Detached) ->
    extract_run_detach(Rest, [Form | Acc], Detached).

maybe_detached_run(Run, true) ->
    Run#{detach => true};
maybe_detached_run(Run, false) ->
    Run.

%% Accumulate errors across all steps rather than stopping at the first bad one.
parse_steps([], Acc, []) ->
    {ok, lists:reverse(Acc)};
parse_steps([], _Acc, ErrAcc) ->
    {error, lists:reverse(ErrAcc)};
parse_steps([[step | Rest] | More], Acc, ErrAcc) ->
    case parse_step(Rest) of
        {ok, Step} ->
            parse_steps(More, [Step | Acc], ErrAcc);
        {error, Diags} ->
            parse_steps(More, Acc, lists:reverse(Diags) ++ ErrAcc)
    end;
parse_steps([[Head | _] | More], Acc, ErrAcc) when is_atom(Head) ->
    Diag = #{code => unknown_form,
             message => iolist_to_binary(
                 io_lib:format("run child form must be 'step', got '~s'", [Head])),
             line => 0},
    parse_steps(More, Acc, [Diag | ErrAcc]);
parse_steps([Form | More], Acc, ErrAcc) when is_list(Form) ->
    Diag = #{code => unknown_form,
             message => <<"run child form must be a list headed by 'step'">>,
             line => 0},
    parse_steps(More, Acc, [Diag | ErrAcc]);
parse_steps([Other | More], Acc, ErrAcc) ->
    Diag = #{code => unknown_form,
             message => iolist_to_binary(
                 io_lib:format("unexpected form inside run: ~p", [Other])),
             line => 0},
    parse_steps(More, Acc, [Diag | ErrAcc]).

%% Validate successfully parsed steps: check for duplicate ids and invalid from_step refs.
validate_steps(Steps) ->
    DupDiags = check_duplicate_ids(Steps),
    FromStepDiags = check_from_step_refs(Steps),
    DupDiags ++ FromStepDiags.

check_duplicate_ids(Steps) ->
    Ids = [maps:get(id, S) || S <- Steps],
    Seen = lists:foldl(fun(Id, {SeenSet, DupSet}) ->
        case sets:is_element(Id, SeenSet) of
            true  -> {SeenSet, sets:add_element(Id, DupSet)};
            false -> {sets:add_element(Id, SeenSet), DupSet}
        end
    end, {sets:new(), sets:new()}, Ids),
    {_, DupIds} = Seen,
    lists:map(fun(Id) ->
        #{code => duplicate_step_id,
          message => iolist_to_binary(io_lib:format("duplicate step id: '~s'", [Id])),
          line => 0}
    end, sets:to_list(DupIds)).

check_from_step_refs(Steps) ->
    %% Walk steps in order, maintaining a set of ids seen so far.
    %% A from_step reference is invalid if the target id is not in the seen set.
    {_, Diags} = lists:foldl(fun(Step, {SeenIds, Acc}) ->
        Id = maps:get(id, Step),
        Args = maps:get(args, Step, #{}),
        StepDiags = check_args_from_step(Args, SeenIds),
        {sets:add_element(Id, SeenIds), Acc ++ StepDiags}
    end, {sets:new(), []}, Steps),
    Diags.

check_args_from_step(#{from_step := RefId}, SeenIds) ->
    case sets:is_element(RefId, SeenIds) of
        true  -> [];
        false ->
            [#{code => invalid_from_step,
               message => iolist_to_binary(
                   io_lib:format("from_step references unknown or forward step id: '~s'", [RefId])),
               line => 0}]
    end;
check_args_from_step(Args, SeenIds) ->
    %% Check field-level {from_step, Id} values in the args map.
    maps:fold(fun(_Key, {from_step, RefId}, Acc) ->
        case sets:is_element(RefId, SeenIds) of
            true  -> Acc;
            false ->
                [#{code => invalid_from_step,
                   message => iolist_to_binary(
                       io_lib:format("from_step references unknown or forward step id: '~s'", [RefId])),
                   line => 0} | Acc]
        end;
    (_Key, _Val, Acc) -> Acc
    end, [], Args).

parse_step([Id, Tool | ChildForms]) when is_atom(Id), is_atom(Tool) ->
    case parse_step_children(ChildForms, #{args => #{}}, []) of
        {ok, Partial} ->
            {ok, Partial#{id => Id, tool => Tool}};
        {error, Diags} ->
            {error, Diags}
    end;
parse_step(_Other) ->
    {error, [#{code => invalid_step,
               message => <<"step form must be (step <id> <tool> ...): missing id or tool">>,
               line => 0}]}.

%% Accumulate errors across step children as well.
parse_step_children([], Acc, []) ->
    {ok, Acc};
parse_step_children([], _Acc, ErrAcc) ->
    {error, lists:reverse(ErrAcc)};
parse_step_children([[args | KVPairs] | Rest], Acc, ErrAcc) ->
    case parse_args(KVPairs, #{}) of
        {ok, ArgsMap} ->
            parse_step_children(Rest, Acc#{args => ArgsMap}, ErrAcc);
        {error, Diags} ->
            parse_step_children(Rest, Acc, lists:reverse(Diags) ++ ErrAcc)
    end;
parse_step_children([[timeout_ms, N] | Rest], Acc, ErrAcc) when is_integer(N), N > 0 ->
    parse_step_children(Rest, Acc#{timeout_ms => N}, ErrAcc);
parse_step_children([[timeout_ms, N] | Rest], Acc, ErrAcc) when is_integer(N) ->
    %% N is 0 or negative
    Diag = #{code => invalid_timeout,
             message => iolist_to_binary(
                 io_lib:format("timeout_ms must be a positive integer, got: ~p", [N])),
             line => 0},
    parse_step_children(Rest, Acc, [Diag | ErrAcc]);
parse_step_children([[timeout_ms, V] | Rest], Acc, ErrAcc) ->
    %% V is not an integer (e.g. a string)
    Diag = #{code => invalid_timeout,
             message => iolist_to_binary(
                 io_lib:format("timeout_ms must be a positive integer, got: ~p", [V])),
             line => 0},
    parse_step_children(Rest, Acc, [Diag | ErrAcc]);
parse_step_children([[Head | _] | Rest], Acc, ErrAcc) when is_atom(Head) ->
    Diag = #{code => unknown_form,
             message => iolist_to_binary(
                 io_lib:format("unknown step child form: '~s' (expected 'args' or 'timeout_ms')", [Head])),
             line => 0},
    parse_step_children(Rest, Acc, [Diag | ErrAcc]);
parse_step_children([Form | Rest], Acc, ErrAcc) when is_list(Form) ->
    Diag = #{code => unknown_form,
             message => <<"unknown step child form (expected 'args' or 'timeout_ms')">>,
             line => 0},
    parse_step_children(Rest, Acc, [Diag | ErrAcc]);
parse_step_children([Other | Rest], Acc, ErrAcc) ->
    Diag = #{code => unknown_form,
             message => iolist_to_binary(
                 io_lib:format("unexpected token in step children: ~p", [Other])),
             line => 0},
    parse_step_children(Rest, Acc, [Diag | ErrAcc]).

parse_args([], Acc) ->
    {ok, Acc};
parse_args([[from_step, Id]], Acc) when map_size(Acc) =:= 0 ->
    {ok, #{from_step => Id}};
parse_args([[from_step, _Id]], _Acc) ->
    {error, [#{code => invalid_step,
               message => <<"bare (from_step Id) must be the only arg entry">>,
               line => 0}]};
parse_args([[Key, Value] | Rest], Acc) when is_atom(Key) ->
    RealValue = coerce_value(Value),
    parse_args(Rest, Acc#{Key => RealValue});
parse_args([[Key | _] | _], _Acc) when is_atom(Key) ->
    {error, [#{code => invalid_step,
               message => iolist_to_binary(
                   io_lib:format("malformed arg pair for key '~s'", [Key])),
               line => 0}]};
parse_args([Other | _], _Acc) ->
    {error, [#{code => invalid_step,
               message => iolist_to_binary(
                   io_lib:format("unexpected token in args: ~p", [Other])),
               line => 0}]}.

coerce_value(V) when is_binary(V) -> V;
coerce_value(V) when is_integer(V) -> V;
coerce_value(V) when is_atom(V) -> V;
coerce_value([from_step, Id]) -> {from_step, Id};
coerce_value(V) when is_list(V) -> V.
