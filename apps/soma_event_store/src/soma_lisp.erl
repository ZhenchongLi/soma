%% @doc Pure term -> Lisp s-expr renderer. The inverse of the soma_lfe
%% parse mapping: atoms render as symbols (with `_' -> `-' in the symbol
%% text), binaries as double-quoted escaped strings, numbers as their text,
%% lists as `(a b c)', and maps as tagged/pair forms. Output is iodata().
-module(soma_lisp).

-export([render/1]).

-spec render(term()) -> iodata().
render(Map) when is_map(Map) ->
    case is_result_map(Map) of
        true ->
            ["(result ",
             render_pair(status, maps:get(status, Map)), " ",
             render_pair(outputs, maps:get(outputs, Map)), " ",
             render_pair(correlation_id, maps:get(correlation_id, Map)),
             ")"];
        false ->
            case is_event_map(Map) of
                true ->
                    Pairs = [render_pair(K, V) || {K, V} <- maps:to_list(Map)],
                    ["(event ", lists:join(" ", Pairs), ")"];
                false ->
                    render_value(Map)
            end
    end;
render(Atom) when is_atom(Atom) ->
    render_symbol(Atom);
render(Bin) when is_binary(Bin) ->
    render_string(Bin);
render(Int) when is_integer(Int) ->
    integer_to_list(Int);
render(Float) when is_float(Float) ->
    io_lib:format("~p", [Float]);
render(List) when is_list(List) ->
    ["(", lists:join(" ", [render(E) || E <- List]), ")"];
render(Other) ->
    %% No s-expr form (pid/ref/fun/port): render as a quoted string,
    %% mirroring jsonable/1's fall-through. Never crashes.
    render_string(iolist_to_binary(io_lib:format("~p", [Other]))).

render_pair(Key, Value) ->
    ["(", render_symbol(Key), " ", render_value(Value), ")"].

%% Render a value in pair-value position. A single-key map whose value is a
%% leaf collapses to its bare `(k v)' pair, so `#{value => <<"hi">>}' reads
%% as `(value "hi")'. Any other map renders as the wrapped list-of-pairs form
%% `((k v) (k v) ...)'.
render_value(Map) when is_map(Map) ->
    case maps:to_list(Map) of
        [{K, V}] when not is_map(V) ->
            render_pair(K, V);
        Pairs ->
            ["(", lists:join(" ", [render_pair(K, V) || {K, V} <- Pairs]), ")"]
    end;
render_value(Value) ->
    render(Value).

is_event_map(Map) ->
    maps:is_key(event_type, Map).

is_result_map(Map) ->
    lists:all(fun(K) -> maps:is_key(K, Map) end,
              [status, outputs, correlation_id]).

render_symbol(Atom) when is_atom(Atom) ->
    %% `_' in the atom maps back to `-' in the Lisp symbol text.
    string:replace(atom_to_list(Atom), "_", "-", all).

render_string(Bin) when is_binary(Bin) ->
    ["\"", escape(Bin), "\""].

escape(Bin) ->
    escape(Bin, []).

escape(<<>>, Acc) ->
    lists:reverse(Acc);
escape(<<$\\, Rest/binary>>, Acc) ->
    escape(Rest, [<<"\\\\">> | Acc]);
escape(<<$", Rest/binary>>, Acc) ->
    escape(Rest, [<<"\\\"">> | Acc]);
escape(<<C, Rest/binary>>, Acc) ->
    escape(Rest, [<<C>> | Acc]).
