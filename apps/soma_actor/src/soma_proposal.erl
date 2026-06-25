%% soma_proposal validates raw LLM output into a tagged proposal.
%%
%% Pure module, mirroring soma_tool_manifest:normalize/1 and soma_lfe:compile/2:
%% no processes, no events. It branches on the `kind` tag field and checks the
%% required fields for that kind, returning {ok, Proposal} | {error, [Diagnostic]}.
-module(soma_proposal).

-export([normalize/1]).

-type proposal() :: map().
-type diagnostic() :: map().

-spec normalize(map()) -> {ok, proposal()} | {error, [diagnostic()]}.
normalize(#{kind := reply, text := Text}) when is_binary(Text) ->
    {ok, #{kind => reply, text => Text}};
normalize(#{kind := run_steps, steps := Steps}) when is_list(Steps) ->
    case lists:all(fun valid_step/1, Steps) of
        true -> {ok, #{kind => run_steps, steps => Steps}}
    end;
normalize(#{kind := reject, reason := Reason}) when is_binary(Reason) ->
    {ok, #{kind => reject, reason => Reason}};
normalize(#{kind := ask, question := Question}) when is_binary(Question) ->
    {ok, #{kind => ask, question => Question}};
normalize(#{kind := Kind}) ->
    {error, [#{code => unknown_kind,
               message => <<"unknown proposal kind">>,
               kind => Kind}]}.

valid_step(Step) when is_map(Step) ->
    maps:is_key(id, Step) andalso maps:is_key(tool, Step);
valid_step(_Step) ->
    false.
