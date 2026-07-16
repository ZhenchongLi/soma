%% @doc Walks raw form list from soma_lfe_reader and produces the internal
%% run representation, or a list of structured diagnostics.
-module(soma_lfe_parser).

-export([parse_run/1, parse_task/1, parse_msg/1, parse_explore/1,
         parse_invoke/1, parse_proposal/1, parse_ask/1, parse_trace/1,
         parse_status/1, parse_result/1, parse_watch/1, parse_cancel/1,
         parse_stop/1]).

-type diagnostic() :: #{code => atom(), message => binary(), line => non_neg_integer()}.

%% @doc Parse a service invocation into the candidate map accepted by the
%% actor-layer service-envelope normalizer.
-spec parse_invoke([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_invoke([invoke | SubForms]) ->
    case parse_invoke_fields(SubForms, {#{kind => invoke}, #{}}) of
        {ok, #{operation := {tool, Tool, Args}} = Envelope} ->
            Step0 = #{tool => Tool, args => Args},
            Step = case maps:find(request_id, Envelope) of
                {ok, RequestId} -> Step0#{id => RequestId};
                error -> Step0
            end,
            {ok, Envelope#{operation => #{kind => tool, step => Step}}};
        {ok, #{operation := {steps, Steps}} = Envelope} ->
            {ok, Envelope#{operation => #{kind => steps, steps => Steps}}};
        {error, Diags} ->
            {error, Diags};
        {ok, _Envelope} ->
            invalid_invoke_operation()
    end.

parse_invoke_fields([], {Envelope, _Seen}) ->
    {ok, Envelope};
parse_invoke_fields([['api-version', Value] | Rest], Acc) ->
    add_invoke_field(api_version, Value, Rest, Acc);
parse_invoke_fields([['request-id', Value] | Rest], Acc) ->
    add_invoke_field(request_id, Value, Rest, Acc);
parse_invoke_fields([[tool | ToolFields] | Rest], Acc) ->
    case claim_invoke_operation(tool, Acc) of
        {ok, Claimed} ->
            case parse_invoke_tool(ToolFields, {#{}, #{}}) of
                {ok, Tool, Args} ->
                    parse_invoke_fields(
                        Rest,
                        set_acc_field(operation, {tool, Tool, Args}, Claimed)
                    );
                {error, Diags} ->
                    {error, Diags}
            end;
        {error, Diags} ->
            {error, Diags}
    end;
parse_invoke_fields([[steps | StepForms] | Rest], Acc) ->
    case claim_invoke_operation(steps, Acc) of
        {ok, Claimed} ->
            case parse_proposal_steps(StepForms) of
                {ok, Steps} ->
                    parse_invoke_fields(
                        Rest,
                        set_acc_field(operation, {steps, Steps}, Claimed)
                    );
                {error, _Diags} ->
                    invalid_invoke_operation()
            end;
        {error, Diags} ->
            {error, Diags}
    end;
parse_invoke_fields([[scope | Values] | Rest], Acc) ->
    add_invoke_field(scope, Values, Rest, Acc);
parse_invoke_fields([['deadline-ms', Value] | Rest], Acc) ->
    add_invoke_field(deadline_ms, Value, Rest, Acc);
parse_invoke_fields([['max-output-bytes', Value] | Rest], Acc) ->
    add_invoke_field(max_output_bytes, Value, Rest, Acc);
parse_invoke_fields([['correlation-id', Value] | Rest], Acc) ->
    add_invoke_field(correlation_id, Value, Rest, Acc);
parse_invoke_fields([[artifacts | Values] | Rest], Acc) ->
    add_invoke_field(artifacts, Values, Rest, Acc);
parse_invoke_fields([[{external_symbol, _Name} | _] | _], _Acc) ->
    unknown_invoke_field();
parse_invoke_fields([[Head | _] | _], Acc) when is_atom(Head) ->
    malformed_or_unknown_invoke_field(Head, Acc);
parse_invoke_fields([_Other | _], _Acc) ->
    invalid_invoke_operation().

add_invoke_field(Field, Value, Rest, Acc) ->
    case claim_unique_field(Field, Acc) of
        {ok, Claimed} ->
            parse_invoke_fields(Rest, set_acc_field(Field, Value, Claimed));
        {error, Diags} ->
            {error, Diags}
    end.

claim_unique_field(Field, {Values, Seen}) ->
    case maps:is_key(Field, Seen) of
        true ->
            duplicate_invoke_field();
        false ->
            {ok, {Values, Seen#{Field => true}}}
    end.

claim_invoke_operation(Kind, {Envelope, Seen}) ->
    case maps:find(operation, Seen) of
        error ->
            {ok, {Envelope, Seen#{operation => Kind}}};
        {ok, Kind} ->
            duplicate_invoke_field();
        {ok, _OtherKind} ->
            invalid_invoke_operation()
    end.

set_acc_field(Field, Value, {Values, Seen}) ->
    {Values#{Field => Value}, Seen}.

malformed_or_unknown_invoke_field(Head, {_Envelope, Seen}) ->
    case invoke_field_descriptor(Head) of
        {field, Field} ->
            case maps:is_key(Field, Seen) of
                true -> duplicate_invoke_field();
                false -> invalid_invoke_operation()
            end;
        {operation, Kind} ->
            case maps:find(operation, Seen) of
                {ok, Kind} -> duplicate_invoke_field();
                _ -> invalid_invoke_operation()
            end;
        unknown ->
            unknown_invoke_field()
    end.

invoke_field_descriptor('api-version') -> {field, api_version};
invoke_field_descriptor('request-id') -> {field, request_id};
invoke_field_descriptor(tool) -> {operation, tool};
invoke_field_descriptor(steps) -> {operation, steps};
invoke_field_descriptor(scope) -> {field, scope};
invoke_field_descriptor('deadline-ms') -> {field, deadline_ms};
invoke_field_descriptor('max-output-bytes') -> {field, max_output_bytes};
invoke_field_descriptor('correlation-id') -> {field, correlation_id};
invoke_field_descriptor(artifacts) -> {field, artifacts};
invoke_field_descriptor(_Head) -> unknown.

parse_invoke_tool([], {#{name := Tool, args := Args}, _Seen}) ->
    {ok, Tool, Args};
parse_invoke_tool([[name, Tool] | Rest], Acc) when is_atom(Tool) ->
    case claim_unique_field(name, Acc) of
        {ok, Claimed} ->
            parse_invoke_tool(Rest, set_acc_field(name, Tool, Claimed));
        {error, Diags} ->
            {error, Diags}
    end;
parse_invoke_tool([[name, _Tool] | _], {_Fields, Seen}) ->
    case maps:is_key(name, Seen) of
        true -> duplicate_invoke_field();
        false -> invalid_invoke_operation()
    end;
parse_invoke_tool([[args | ArgForms] | Rest], Acc) ->
    case claim_unique_field(args, Acc) of
        {ok, Claimed} ->
            case parse_args(ArgForms, #{}) of
                {ok, Args} ->
                    parse_invoke_tool(
                        Rest,
                        set_acc_field(args, Args, Claimed)
                    );
                {error, _Diags} ->
                    invalid_invoke_operation()
            end;
        {error, Diags} ->
            {error, Diags}
    end;
parse_invoke_tool([[Head | _] | _], {_Fields, Seen}) when is_atom(Head) ->
    case (Head =:= name orelse Head =:= args) andalso maps:is_key(Head, Seen) of
        true -> duplicate_invoke_field();
        false -> invalid_invoke_operation()
    end;
parse_invoke_tool(_Other, _Acc) ->
    invalid_invoke_operation().

duplicate_invoke_field() ->
    {error, [#{code => duplicate_field,
               message => <<"invoke field is duplicated">>,
               line => 0}]}.

unknown_invoke_field() ->
    {error, [#{code => unknown_field,
               message => <<"invoke field is unknown">>,
               line => 0}]}.

invalid_invoke_operation() ->
    {error, [#{code => invalid_operation,
               message => <<"invoke operation is invalid">>,
               line => 0}]}.

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
    case parse_proposal_steps(StepForms) of
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
parse_task(Form) ->
    case find_unsupported_task_control_form(Form) of
        {ok, Head} ->
            {error, [task_reserved_control_form_diag(Head)]};
        none ->
            parse_task_checked(Form)
    end.

parse_task_checked([task, [detach], LetStar]) ->
    parse_task_let_star(LetStar, #{detach => true});
parse_task_checked([task, LetStar]) ->
    parse_task_let_star(LetStar, #{});
parse_task_checked([task | _]) ->
    invalid_task_form().

invalid_task_form() ->
    {error, [#{code => invalid_task_form,
               message => <<"task form must be (task (let* ((id (tool name ...))) (return id)))">>,
               line => 0}]}.

parse_task_let_star(['let*', Bindings, [return, ReturnId0]], RunFields)
        when is_list(Bindings) ->
    case parse_run_identifier(ReturnId0) of
        {ok, ReturnId} ->
            case parse_task_bindings(Bindings, [], []) of
                {ok, Steps} ->
                    case validate_task_steps(Steps) ++
                         validate_task_return(ReturnId, Steps) of
                        [] ->
                            {ok, #{run => RunFields#{steps => Steps}}};
                        Diags ->
                            {error, Diags}
                    end;
                {error, Diags} ->
                    {error, Diags}
            end;
        error ->
            invalid_task_form()
    end;
parse_task_let_star(['let*', Bindings, [return, ReturnId0] | _ExtraBody], _RunFields)
        when is_list(Bindings) ->
    case parse_run_identifier(ReturnId0) of
        {ok, _ReturnId} ->
            invalid_task_let_star();
        error ->
            invalid_task_form()
    end;
parse_task_let_star(['let*', Bindings], _RunFields) when is_list(Bindings) ->
    {error, [#{code => invalid_return,
               message => <<"task let* body must include (return Name)">>,
               line => 0}]};
parse_task_let_star(_Other, _RunFields) ->
    invalid_task_form().

invalid_task_let_star() ->
    {error, [#{code => invalid_let_star,
               message => <<"task let* body must contain exactly one return form">>,
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

parse_task_binding([Id0, ToolForm]) ->
    case parse_run_identifier(Id0) of
        {ok, Id} ->
            parse_task_binding_with_id(Id, ToolForm);
        error ->
            invalid_task_binding()
    end;
parse_task_binding(_Other) ->
    invalid_task_binding().

parse_task_binding_with_id(Id, ToolForm) ->
    case is_reserved_task_word(Id) of
        true ->
            {error, [task_reserved_form_diag(Id)]};
        false ->
            parse_task_tool_form(Id, ToolForm)
    end.

parse_task_tool_form(Id, [tool, Tool0 | ArgForms] = ToolForm) ->
    case parse_run_identifier(Tool0) of
        {ok, Tool} ->
            parse_task_tool_call(Id, Tool, ArgForms);
        error ->
            {error, [task_invalid_tool_form_diag(ToolForm)]}
    end;
parse_task_tool_form(_Id, [tool | _] = ToolForm) ->
    {error, [task_invalid_tool_form_diag(ToolForm)]};
parse_task_tool_form(_Id, _ToolForm) ->
    invalid_task_binding().

invalid_task_binding() ->
    {error, [#{code => invalid_binding,
               message => <<"task let* bindings must be (id (tool name ...)) pairs">>,
               line => 0}]}.

is_reserved_task_word(Word) ->
    lists:member(Word, [task, 'let*', tool, from, 'timeout-ms', return,
                        'if', 'cond', 'loop', 'recur']).

task_reserved_form_diag(Word) ->
    #{code => reserved_form,
      message => iolist_to_binary(
          io_lib:format("reserved task binding name: '~s'", [Word])),
      line => 0}.

find_unsupported_task_control_form([Head | Children]) when is_atom(Head) ->
    case is_unsupported_task_control_head(Head) of
        true ->
            {ok, Head};
        false ->
            find_unsupported_task_control_form_children(Children)
    end;
find_unsupported_task_control_form([Child | Rest]) ->
    case find_unsupported_task_control_form(Child) of
        none ->
            find_unsupported_task_control_form(Rest);
        Found ->
            Found
    end;
find_unsupported_task_control_form([]) ->
    none;
find_unsupported_task_control_form(_Other) ->
    none.

find_unsupported_task_control_form_children([]) ->
    none;
find_unsupported_task_control_form_children([Child | Rest]) ->
    case find_unsupported_task_control_form(Child) of
        none ->
            find_unsupported_task_control_form_children(Rest);
        Found ->
            Found
    end.

is_unsupported_task_control_head(Head) ->
    lists:member(Head, ['if', 'cond', 'loop', 'recur']).

task_reserved_control_form_diag(Head) ->
    #{code => reserved_form,
      message => iolist_to_binary(
          io_lib:format("unsupported task control form head: '~s'", [Head])),
      line => 0}.

parse_task_tool_call(Id, Tool, ArgForms) ->
    case extract_task_step_fields(ArgForms, #{}, [], []) of
        {ok, StepFields, ToolArgForms} ->
            case parse_task_args(ToolArgForms, #{}) of
                {ok, Args} ->
                    {ok, StepFields#{id => Id, tool => Tool, args => Args}};
                {error, Diags} ->
                    {error, Diags}
            end;
        {error, Diags} ->
            {error, Diags}
    end.

task_invalid_tool_form_diag(Form) ->
    #{code => invalid_tool_form,
      message => iolist_to_binary(io_lib:format("malformed task tool form: ~p", [Form])),
      line => 0}.

extract_task_step_fields([], StepFields, RevArgForms, []) ->
    {ok, StepFields, lists:reverse(RevArgForms)};
extract_task_step_fields([], _StepFields, _RevArgForms, ErrAcc) ->
    {error, lists:reverse(ErrAcc)};
extract_task_step_fields([['timeout-ms', N] | Rest], StepFields, RevArgForms, ErrAcc)
        when is_integer(N), N > 0 ->
    case maps:is_key(timeout_ms, StepFields) of
        true ->
            extract_task_step_fields(
                Rest,
                StepFields,
                RevArgForms,
                [task_invalid_timeout_diag(N) | ErrAcc]
            );
        false ->
            extract_task_step_fields(Rest, StepFields#{timeout_ms => N}, RevArgForms, ErrAcc)
    end;
extract_task_step_fields([['timeout-ms', Value] | Rest], StepFields, RevArgForms, ErrAcc) ->
    extract_task_step_fields(
        Rest,
        StepFields,
        RevArgForms,
        [task_invalid_timeout_diag(Value) | ErrAcc]
    );
extract_task_step_fields([['timeout-ms' | _] = Form | Rest], StepFields, RevArgForms, ErrAcc) ->
    extract_task_step_fields(
        Rest,
        StepFields,
        RevArgForms,
        [task_invalid_timeout_diag(Form) | ErrAcc]
    );
extract_task_step_fields([ArgForm | Rest], StepFields, RevArgForms, ErrAcc) ->
    extract_task_step_fields(Rest, StepFields, [ArgForm | RevArgForms], ErrAcc).

task_invalid_timeout_diag(Value) ->
    #{code => invalid_timeout,
      message => iolist_to_binary(
          io_lib:format("timeout-ms must be a positive integer, got: ~p", [Value])),
      line => 0}.

parse_task_args([[from, Id]], Acc) when map_size(Acc) =:= 0 ->
    {ok, #{from_step => coerce_identifier(Id)}};
parse_task_args(ArgForms, Acc) ->
    case task_args_have_mixed_bare_from(ArgForms) of
        true ->
            {error, [task_invalid_tool_form_diag(ArgForms)]};
        false ->
            case parse_args(rewrite_task_from_values(ArgForms), Acc) of
                {ok, Args} ->
                    {ok, Args};
                {error, Diags} ->
                    {error, [Diag#{code => invalid_tool_form} || Diag <- Diags]}
            end
    end.

task_args_have_mixed_bare_from(ArgForms) ->
    length(ArgForms) > 1 andalso lists:any(fun
        ([from, _Id]) -> true;
        (_Other) -> false
    end, ArgForms).

rewrite_task_from_values([[Key, [from, Id]] | Rest]) when is_atom(Key) ->
    [[Key, [from_step, Id]] | rewrite_task_from_values(Rest)];
rewrite_task_from_values([Arg | Rest]) ->
    [Arg | rewrite_task_from_values(Rest)];
rewrite_task_from_values([]) ->
    [].

validate_task_steps(Steps) ->
    check_duplicate_bindings(Steps) ++ check_task_from_binding_refs(Steps).

check_duplicate_bindings(Steps) ->
    Ids = [maps:get(id, S) || S <- Steps],
    Seen = lists:foldl(fun(Id, {SeenSet, DupSet}) ->
        case sets:is_element(Id, SeenSet) of
            true  -> {SeenSet, sets:add_element(Id, DupSet)};
            false -> {sets:add_element(Id, SeenSet), DupSet}
        end
    end, {sets:new(), sets:new()}, Ids),
    {_, DupIds} = Seen,
    lists:map(fun(Id) ->
        #{code => duplicate_binding,
          message => iolist_to_binary(io_lib:format("duplicate binding: '~s'", [Id])),
          line => 0}
    end, sets:to_list(DupIds)).

check_task_from_binding_refs(Steps) ->
    [Diag#{code => invalid_from_binding} || Diag <- check_from_step_refs(Steps)].

validate_task_return(ReturnId, Steps) ->
    case lists:any(fun(Step) -> maps:get(id, Step) =:= ReturnId end, Steps) of
        true ->
            [];
        false ->
            [#{code => invalid_return,
               message => iolist_to_binary(
                   io_lib:format("task return references unknown binding: '~s'", [ReturnId])),
               line => 0}]
    end.

parse_proposal_steps(StepForms) ->
    parse_proposal_steps(StepForms, []).

parse_proposal_steps([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_proposal_steps([[step | StepChildren] | Rest], Acc) ->
    case parse_proposal_step(StepChildren, #{args => #{}}) of
        {ok, Step} ->
            parse_proposal_steps(Rest, [Step | Acc]);
        {error, Diags} ->
            {error, Diags}
    end;
parse_proposal_steps([[Head | _] | _], _Acc) when is_atom(Head) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("steps child form must be 'step', got '~s'", [Head])),
               line => 0}]};
parse_proposal_steps([Other | _], _Acc) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unexpected form inside steps: ~p", [Other])),
               line => 0}]}.

parse_proposal_step([], Acc) ->
    validate_proposal_step(Acc);
%% Step ids and tool names are caller-defined identifiers. Symbol, string,
%% and safe-mode fresh-symbol spellings are all total: a fresh symbol (an
%% {external_symbol, _} token from the existing_atoms_only reader) and a
%% string both become binaries, so acceptance never depends on whether some
%% earlier code happened to intern the spelling.
parse_proposal_step([[id, Id] | Rest], Acc) when is_atom(Id); is_binary(Id) ->
    parse_proposal_step(Rest, Acc#{id => Id});
parse_proposal_step([[id, {external_symbol, Id}] | Rest], Acc) ->
    parse_proposal_step(Rest, Acc#{id => Id});
parse_proposal_step([[tool, Tool] | Rest], Acc)
        when is_atom(Tool); is_binary(Tool) ->
    parse_proposal_step(Rest, Acc#{tool => Tool});
parse_proposal_step([[tool, {external_symbol, Tool}] | Rest], Acc) ->
    parse_proposal_step(Rest, Acc#{tool => Tool});
parse_proposal_step([[args | KVPairs] | Rest], Acc) ->
    case parse_args(KVPairs, #{}) of
        {ok, ArgsMap} ->
            parse_proposal_step(Rest, Acc#{args => ArgsMap});
        {error, Diags} ->
            {error, Diags}
    end;
parse_proposal_step([[timeout_ms, TimeoutMs] | Rest], Acc)
        when is_integer(TimeoutMs), TimeoutMs > 0 ->
    parse_proposal_step(Rest, Acc#{timeout_ms => TimeoutMs});
parse_proposal_step([[id, _] | _], _Acc) ->
    invalid_proposal_step();
parse_proposal_step([[tool, _] | _], _Acc) ->
    invalid_proposal_step();
parse_proposal_step([[timeout_ms, _] | _], _Acc) ->
    invalid_proposal_step();
parse_proposal_step([[Head | _] | _], _Acc) when is_atom(Head) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format(
                       "unknown step child form: '~s' "
                       "(expected 'id', 'tool', 'args' or 'timeout_ms')",
                       [Head]
                   )),
               line => 0}]};
parse_proposal_step([Other | _], _Acc) ->
    {error, [#{code => unknown_form,
               message => iolist_to_binary(
                   io_lib:format("unexpected token in step children: ~p", [Other])),
               line => 0}]}.

validate_proposal_step(#{id := Id, tool := Tool} = Step)
        when (is_atom(Id) orelse is_binary(Id)),
             (is_atom(Tool) orelse is_binary(Tool)) ->
    {ok, Step};
validate_proposal_step(_Step) ->
    invalid_proposal_step().

invalid_proposal_step() ->
    {error, [#{code => invalid_step,
               message => <<"proposal step requires atom id and tool fields">>,
               line => 0}]}.

%% @doc Parse a single explore form to canonical, compile-only step data.
-spec parse_explore([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_explore([explore]) ->
    {error, [#{code => empty_explore,
               message => <<"explore requires at least one step">>,
               line => 0}]};
parse_explore([explore | StepForms]) ->
    case parse_proposal_steps(StepForms) of
        {ok, Steps} ->
            {ok, #{kind => explore, steps => Steps}};
        {error, _Diags} ->
            {error, [first_explore_diagnostic(StepForms)]}
    end.

first_explore_diagnostic([[step | StepChildren] | Rest]) ->
    case parse_proposal_step(StepChildren, #{args => #{}}) of
        {ok, _Step} ->
            first_explore_diagnostic(Rest);
        {error, _Diags} ->
            #{code => invalid_explore_step,
              message => <<"explore contains a malformed step">>,
              line => 0}
    end;
first_explore_diagnostic([_Other | _]) ->
    #{code => unknown_explore_form,
      message => <<"explore accepts only step forms">>,
      line => 0}.

%% @doc Parse a single proposal form into the #{kind => ...} map
%% soma_proposal:normalize/1 accepts.
-spec parse_proposal([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_proposal([reply, [text, Text]]) when is_binary(Text) ->
    {ok, #{kind => reply, text => Text}};
parse_proposal([reject, [reason, Reason]]) when is_binary(Reason) ->
    {ok, #{kind => reject, reason => Reason}};
parse_proposal(['run-steps' | StepForms]) ->
    case parse_proposal_steps(StepForms) of
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

-spec parse_result([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_result([result, TaskId]) when is_binary(TaskId) ->
    {ok, #{result => #{task_id => TaskId}}};
parse_result(_Other) ->
    {error, [#{code => malformed_form,
               message => <<"result requires a single string argument: (result \"<task-id>\")">>,
               line => 0}]}.

-spec parse_watch([term()]) -> {ok, map()} | {error, [diagnostic()]}.
parse_watch([watch, TaskId | Fields]) when is_binary(TaskId) ->
    case parse_watch_fields(Fields, #{task_id => TaskId}) of
        {ok, Watch} ->
            {ok, #{watch => Watch}};
        {error, _Diagnostics} = Error ->
            Error
    end;
parse_watch(_Other) ->
    invalid_watch().

parse_watch_fields([], #{limit := _Limit} = Watch) ->
    {ok, Watch};
parse_watch_fields([], _Watch) ->
    invalid_watch();
parse_watch_fields([[limit, Limit] | Rest], Watch)
  when is_integer(Limit), Limit > 0 ->
    add_watch_field(limit, Limit, Rest, Watch);
parse_watch_fields([[cursor, Cursor] | Rest], Watch)
  when is_binary(Cursor) ->
    add_watch_field(cursor, Cursor, Rest, Watch);
parse_watch_fields([[limit, _Invalid] | _Rest], _Watch) ->
    invalid_watch();
parse_watch_fields([[cursor, _Invalid] | _Rest], _Watch) ->
    invalid_watch();
parse_watch_fields([[Head | _Values] | _Rest], _Watch)
  when is_atom(Head) ->
    {error, [#{code => unknown_field,
               message => <<"watch field is unknown">>,
               line => 0}]};
parse_watch_fields([[{external_symbol, _Name} | _Values] | _Rest], _Watch) ->
    {error, [#{code => unknown_field,
               message => <<"watch field is unknown">>,
               line => 0}]};
parse_watch_fields(_Other, _Watch) ->
    invalid_watch().

add_watch_field(Field, Value, Rest, Watch) ->
    case maps:is_key(Field, Watch) of
        true ->
            {error, [#{code => duplicate_field,
                       message => <<"watch field is duplicated">>,
                       line => 0}]};
        false ->
            parse_watch_fields(Rest, Watch#{Field => Value})
    end.

invalid_watch() ->
    {error, [#{code => invalid_watch,
               message => <<"watch requires a task id and positive limit">>,
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
    %% A from_step reference is invalid if the target id is not in the seen
    %% set. Ids compare by spelling: a symbol id and a string/fresh-symbol
    %% reference of the same name refer to the same step.
    {_, Diags} = lists:foldl(fun(Step, {SeenIds, Acc}) ->
        Id = identifier_spelling(maps:get(id, Step)),
        Args = maps:get(args, Step, #{}),
        StepDiags = check_args_from_step(Args, SeenIds),
        {sets:add_element(Id, SeenIds), Acc ++ StepDiags}
    end, {sets:new(), []}, Steps),
    Diags.

identifier_spelling(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
identifier_spelling(Id) when is_binary(Id) -> Id.

check_args_from_step(#{from_step := RefId0}, SeenIds) ->
    RefId = identifier_spelling(RefId0),
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
    maps:fold(fun(_Key, {from_step, RefId0}, Acc) ->
        RefId = identifier_spelling(RefId0),
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

parse_step([Id0, Tool0 | ChildForms]) ->
    case {parse_run_identifier(Id0), parse_run_identifier(Tool0)} of
        {{ok, Id}, {ok, Tool}} ->
            case parse_step_children(ChildForms, #{args => #{}}, []) of
                {ok, Partial} ->
                    {ok, Partial#{id => Id, tool => Tool}};
                {error, Diags} ->
                    {error, Diags}
            end;
        _ ->
            invalid_run_step()
    end;
parse_step(_Other) ->
    invalid_run_step().

parse_run_identifier(Value) when is_atom(Value) ->
    {ok, Value};
parse_run_identifier({external_symbol, Value}) when is_binary(Value) ->
    {ok, Value};
parse_run_identifier(_Value) ->
    error.

invalid_run_step() ->
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
    {ok, #{from_step => coerce_identifier(Id)}};
parse_args([[from_step, _Id] | _Rest], _Acc) ->
    {error, [#{code => invalid_step,
               message => <<"bare (from_step Id) must be the only arg entry">>,
               line => 0}]};
%% Arg keys accept symbol, string, and safe-mode fresh-symbol spellings;
%% the latter two become binary keys that a consumer maps through a declared
%% vocabulary before execution.
parse_args([[Key, Value] | Rest], Acc) when is_atom(Key); is_binary(Key) ->
    RealValue = coerce_value(Value),
    parse_args(Rest, Acc#{Key => RealValue});
parse_args([[{external_symbol, Key}, Value] | Rest], Acc) ->
    RealValue = coerce_value(Value),
    parse_args(Rest, Acc#{Key => RealValue});
parse_args([[Key | _] | _], _Acc) when is_atom(Key); is_binary(Key) ->
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
%% A fresh symbol read in safe mode is bounded caller data, not a new atom.
coerce_value({external_symbol, Name}) -> Name;
coerce_value([from_step, Id]) -> {from_step, coerce_identifier(Id)};
coerce_value(V) when is_list(V) -> V.

%% from_step references are identifiers like step ids: symbols stay atoms,
%% strings and safe-mode fresh symbols are binaries.
coerce_identifier({external_symbol, Name}) -> Name;
coerce_identifier(Id) -> Id.
