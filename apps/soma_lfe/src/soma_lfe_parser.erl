%% @doc Walks raw form list from soma_lfe_reader and produces the internal
%% run representation, or a list of structured diagnostics.
-module(soma_lfe_parser).

-export([parse_run/1]).

-type diagnostic() :: #{message => binary(), line => non_neg_integer()}.

-spec parse_run([term()]) ->
    {ok, #{run => #{steps => [map()]}}} | {error, [diagnostic()]}.
parse_run([]) ->
    {error, [#{message => <<"expected exactly one top-level form, got none">>, line => 0}]};
parse_run([_Form1, _Form2 | _]) ->
    {error, [#{message => <<"expected exactly one top-level form, got multiple">>, line => 0}]};
parse_run([[run | ChildForms]]) ->
    case parse_steps(ChildForms, []) of
        {ok, Steps} ->
            {ok, #{run => #{steps => Steps}}};
        {error, Diags} ->
            {error, Diags}
    end;
parse_run([[Head | _]]) when is_atom(Head) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("top-level form must be 'run', got '~s'", [Head])),
               line => 0}]};
parse_run([Form]) when is_list(Form) ->
    {error, [#{message => <<"top-level form must be a list headed by 'run'">>, line => 0}]};
parse_run([_Form]) ->
    {error, [#{message => <<"top-level form must be a list headed by 'run'">>, line => 0}]}.

parse_steps([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_steps([[step | Rest] | More], Acc) ->
    case parse_step(Rest) of
        {ok, Step} ->
            parse_steps(More, [Step | Acc]);
        {error, Diags} ->
            {error, Diags}
    end;
parse_steps([[Head | _] | _], _Acc) when is_atom(Head) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("run child form must be 'step', got '~s'", [Head])),
               line => 0}]};
parse_steps([Form | _], _Acc) when is_list(Form) ->
    {error, [#{message => <<"run child form must be a list headed by 'step'">>, line => 0}]};
parse_steps([Other | _], _Acc) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("unexpected form inside run: ~p", [Other])),
               line => 0}]}.

parse_step([Id, Tool | ChildForms]) when is_atom(Id), is_atom(Tool) ->
    case parse_step_children(ChildForms, #{args => #{}}) of
        {ok, Partial} ->
            {ok, Partial#{id => Id, tool => Tool}};
        {error, Diags} ->
            {error, Diags}
    end;
parse_step(_Other) ->
    {error, [#{message => <<"step form must be (step <id> <tool> ...): missing id or tool">>,
               line => 0}]}.

parse_step_children([], Acc) ->
    {ok, Acc};
parse_step_children([[args | KVPairs] | Rest], Acc) ->
    case parse_args(KVPairs, #{}) of
        {ok, ArgsMap} ->
            parse_step_children(Rest, Acc#{args => ArgsMap});
        {error, Diags} ->
            {error, Diags}
    end;
parse_step_children([[timeout_ms, N] | Rest], Acc) when is_integer(N) ->
    parse_step_children(Rest, Acc#{timeout_ms => N});
parse_step_children([[Head | _] | _], _Acc) when is_atom(Head) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("unknown step child form: '~s' (expected 'args' or 'timeout_ms')", [Head])),
               line => 0}]};
parse_step_children([Form | _], _Acc) when is_list(Form) ->
    {error, [#{message => <<"unknown step child form (expected 'args' or 'timeout_ms')">>,
               line => 0}]};
parse_step_children([Other | _], _Acc) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("unexpected token in step children: ~p", [Other])),
               line => 0}]}.

parse_args([], Acc) ->
    {ok, Acc};
parse_args([[from_step, Id]], Acc) when map_size(Acc) =:= 0 ->
    {ok, #{from_step => Id}};
parse_args([[from_step, _Id]], _Acc) ->
    {error, [#{message => <<"bare (from_step Id) must be the only arg entry">>,
               line => 0}]};
parse_args([[Key, Value] | Rest], Acc) when is_atom(Key) ->
    RealValue = coerce_value(Value),
    parse_args(Rest, Acc#{Key => RealValue});
parse_args([[Key | _] | _], _Acc) when is_atom(Key) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("malformed arg pair for key '~s'", [Key])),
               line => 0}]};
parse_args([Other | _], _Acc) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("unexpected token in args: ~p", [Other])),
               line => 0}]}.

coerce_value(V) when is_binary(V) -> V;
coerce_value(V) when is_integer(V) -> V;
coerce_value(V) when is_atom(V) -> V;
coerce_value([from_step, Id]) -> {from_step, Id};
coerce_value(V) when is_list(V) -> V.
