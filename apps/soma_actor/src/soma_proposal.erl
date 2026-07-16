%% soma_proposal validates raw LLM output into a tagged proposal.
%%
%% Pure module, mirroring soma_tool_manifest:normalize/1 and soma_lfe:compile/2:
%% no processes, no events. It branches on the `kind` tag field and checks the
%% required fields for that kind, returning {ok, Proposal} | {error, [Diagnostic]}.
-module(soma_proposal).

-export([normalize/1]).

-type proposal() :: map().
-type diagnostic() :: map().

-spec normalize(term()) -> {ok, proposal()} | {error, [diagnostic()]}.
normalize(#{kind := reply, text := Text}) when is_binary(Text) ->
    {ok, #{kind => reply, text => Text}};
normalize(#{kind := run_steps, steps := Steps}) when is_list(Steps) ->
    case valid_step_list(Steps) of
        true ->
            {ok, #{kind => run_steps, steps => Steps}};
        false ->
            {error, [#{code => invalid_step,
                       message => <<"run_steps proposal has an invalid canonical step">>,
                       kind => run_steps,
                       field => steps}]}
    end;
normalize(#{kind := reject, reason := Reason}) when is_binary(Reason) ->
    {ok, #{kind => reject, reason => Reason}};
normalize(#{kind := ask, question := Question}) when is_binary(Question) ->
    {ok, #{kind => ask, question => Question}};
normalize(#{kind := actor_message, to := To, payload := Payload})
  when is_pid(To), is_map(Payload); is_binary(To), is_map(Payload) ->
    {ok, #{kind => actor_message, to => To, payload => Payload}};
%% An actor_message body may also be a Lisp `(msg ...)' string (binary or iolist)
%% the receiver parses at its own send/2 string clause (L.2). The body shape --
%% map vs Lisp string -- is decided downstream in the actor's delivery; here it is
%% only validated as a non-empty string payload alongside a pid `to'.
normalize(#{kind := actor_message, to := To, payload := Payload})
  when is_pid(To), is_binary(Payload); is_binary(To), is_binary(Payload) ->
    {ok, #{kind => actor_message, to => To, payload => Payload}};
normalize(#{kind := actor_message, to := To, payload := Payload})
  when is_pid(To), is_list(Payload); is_binary(To), is_list(Payload) ->
    {ok, #{kind => actor_message, to => To, payload => Payload}};
normalize(#{kind := reply}) ->
    {error, [#{code => missing_required_field,
               message => <<"reply proposal requires a text field">>,
               kind => reply,
               field => text}]};
normalize(#{kind := actor_message} = Raw) when not is_map_key(to, Raw) ->
    {error, [#{code => missing_required_field,
               message => <<"actor_message proposal requires a to field">>,
               kind => actor_message,
               field => to}]};
normalize(#{kind := actor_message} = Raw) when not is_map_key(payload, Raw) ->
    {error, [#{code => missing_required_field,
               message => <<"actor_message proposal requires a payload field">>,
               kind => actor_message,
               field => payload}]};
normalize(#{kind := Kind}) ->
    {error, [#{code => unknown_kind,
               message => <<"unknown proposal kind">>,
               kind => Kind}]};
normalize(Raw) when is_map(Raw) ->
    {error, [#{code => missing_required_field,
               message => <<"proposal requires a kind field">>,
               field => kind}]};
normalize(_Raw) ->
    {error, [#{code => invalid_proposal,
               message => <<"proposal must be a map">>}]}.

%% A canonical step list is validated as a whole, not just per step:
%% duplicate step ids would alias downstream event correlation (two
%% tool calls sharing one identity), and a from_step reference must
%% point to an earlier step or the runtime crashes resolving it after
%% run.started. Ids compare by spelling so atom and binary forms of
%% the same name cannot smuggle a duplicate past the check.
valid_step_list(Steps) ->
    lists:all(fun valid_step/1, Steps) andalso
        ordered_canonical_steps(Steps, sets:new()).

ordered_canonical_steps([], _SeenIds) ->
    true;
ordered_canonical_steps([#{id := Id} = Step | Rest], SeenIds) ->
    Spelling = id_spelling(Id),
    (not sets:is_element(Spelling, SeenIds)) andalso
        valid_step_references(maps:get(args, Step, #{}), SeenIds) andalso
        ordered_canonical_steps(
          Rest, sets:add_element(Spelling, SeenIds)).

valid_step_references(#{from_step := Reference} = Args, SeenIds)
  when map_size(Args) =:= 1 ->
    sets:is_element(id_spelling(Reference), SeenIds);
valid_step_references(Args, SeenIds) when is_map(Args) ->
    lists:all(
      fun({_Key, {from_step, Reference}}) ->
              sets:is_element(id_spelling(Reference), SeenIds);
         ({_Key, _Value}) ->
              true
      end,
      maps:to_list(Args)).

id_spelling(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
id_spelling(Id) when is_binary(Id) -> Id;
id_spelling(Id) -> Id.

valid_step(#{id := _StepId, tool := _ToolName} = Step) ->
    is_map(maps:get(args, Step, #{})) andalso
        valid_timeout(maps:get(timeout_ms, Step, undefined));
valid_step(_Step) ->
    false.

valid_timeout(undefined) ->
    true;
valid_timeout(TimeoutMs) ->
    is_integer(TimeoutMs) andalso TimeoutMs > 0.
