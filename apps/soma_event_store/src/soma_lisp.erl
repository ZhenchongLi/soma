%% @doc Pure term -> Lisp s-expr renderer. The inverse of the soma_lfe
%% parse mapping: atoms render as symbols (with `_' -> `-' in the symbol
%% text), binaries as double-quoted escaped strings, numbers as their text,
%% lists as `(a b c)', and maps as tagged/pair forms. Output is iodata().
-module(soma_lisp).

-export([render/1]).

-spec render(term()) -> iodata().
render(#{kind := invoke} = Invoke) ->
    render_invoke(Invoke);
render(#{kind := service_reply,
         api_version := ApiVersion,
         operation := Operation,
         value := Value}) ->
    ["(reply ",
     lists:join(
       " ",
       [render_pair(api_version, ApiVersion),
        render_pair(operation, Operation),
        render_pair(value, Value)]),
     ")"];
render(#{kind := service_error,
         api_version := ApiVersion,
         code := Code,
         supported_api_versions := SupportedApiVersions}) ->
    ["(error ",
     lists:join(
       " ",
       [render_pair(api_version, ApiVersion),
        render_pair(code, Code),
        render_pair(supported_api_versions, SupportedApiVersions)]),
     ")"];
render(#{kind := service_error,
         api_version := ApiVersion,
         code := Code}) ->
    ["(error ",
     lists:join(
       " ",
       [render_pair(api_version, ApiVersion),
        render_pair(code, Code)]),
     ")"];
render(#{kind := explore, steps := Steps}) when is_list(Steps) ->
    ["(explore ",
     lists:join(" ", [render_canonical_step(Step) || Step <- Steps]),
     ")"];
render(Map) when is_map(Map) ->
    case is_event_map(Map) of
        true ->
            Pairs = [render_pair(K, V) || {K, V} <- maps:to_list(Map)],
            ["(event ", lists:join(" ", Pairs), ")"];
        false ->
            case is_result_map(Map) of
                true ->
                    ["(result ", lists:join(" ", result_pairs(Map)), ")"];
                false ->
                    case is_envelope_map(Map) of
                        true ->
                            render_envelope(Map);
                        false ->
                            render_value(Map)
                    end
            end
    end;
render(Atom) when is_atom(Atom) ->
    render_symbol(Atom);
render(Bin) when is_binary(Bin) ->
    render_binary(Bin);
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
    ["(", render_map_key(Key), " ", render_value(Value), ")"].

render_map_key(Key) when is_atom(Key) ->
    render_symbol(Key);
render_map_key(Key) when is_binary(Key) ->
    render_binary(Key).

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

%% A (msg ...) envelope parsed by soma_lfe carries a `type' key (with `payload'
%% required alongside it). It renders back to a `(msg ...)' form so it re-parses
%% to the same term.
is_envelope_map(Map) ->
    maps:is_key(type, Map).

%% Render a parsed envelope as `(msg (k v) ...)'. The `steps' field is special:
%% its value is a list of step maps, each of which must render with a `step'
%% head so the result re-parses through soma_lfe.
render_envelope(Map) ->
    Pairs = [render_envelope_pair(K, V) || {K, V} <- maps:to_list(Map)],
    ["(msg ", lists:join(" ", Pairs), ")"].

render_envelope_pair(steps, Steps) when is_list(Steps) ->
    ["(steps ", lists:join(" ", [render_step(S) || S <- Steps]), ")"];
render_envelope_pair(Key, Value) ->
    render_pair(Key, Value).

render_invoke(Invoke) ->
    Fields =
        [render_pair(api_version, maps:get(api_version, Invoke)),
         render_pair(request_id, maps:get(request_id, Invoke)),
         render_invoke_operation(maps:get(operation, Invoke))]
        ++ [render_invoke_list(scope, Value)
            || {ok, Value} <- [maps:find(scope, Invoke)]]
        ++ [render_pair(deadline_ms, Value)
            || {ok, Value} <- [maps:find(deadline_ms, Invoke)]]
        ++ [render_pair(max_output_bytes, Value)
            || {ok, Value} <- [maps:find(max_output_bytes, Invoke)]]
        ++ [render_pair(correlation_id, Value)
            || {ok, Value} <- [maps:find(correlation_id, Invoke)]]
        ++ [render_invoke_list(artifacts, Value)
            || {ok, Value} <- [maps:find(artifacts, Invoke)]],
    ["(invoke ", lists:join(" ", Fields), ")"].

render_invoke_operation(#{kind := tool, step := #{tool := Tool, args := Args}}) ->
    ["(tool (name ", render_canonical_symbol(Tool), ") ",
     render_canonical_args(Args), ")"];
render_invoke_operation(#{kind := steps, steps := Steps}) ->
    ["(steps", [[" ", render_canonical_step(Step)] || Step <- Steps], ")"].

render_invoke_list(Key, Values) ->
    ["(", render_symbol(Key), [[" ", render(Value)] || Value <- Values], ")"].

%% A step map renders as `(step (id ...) (tool ...) (args ...))'.
render_step(Step) when is_map(Step) ->
    Pairs = [render_pair(K, V) || {K, V} <- maps:to_list(Step)],
    ["(step ", lists:join(" ", Pairs), ")"].

render_canonical_step(#{id := Id, tool := Tool, args := Args} = Step) ->
    Fields =
        [["(id ", render_canonical_symbol(Id), ")"],
         ["(tool ", render_canonical_symbol(Tool), ")"],
         render_canonical_args(Args)]
        ++ [["(timeout_ms ", integer_to_list(TimeoutMs), ")"]
            || {ok, TimeoutMs} <- [maps:find(timeout_ms, Step)]],
    ["(step ", lists:join(" ", Fields), ")"].

render_canonical_args(#{from_step := Id} = Args) when map_size(Args) =:= 1 ->
    ["(args (from_step ", render_canonical_value(Id), "))"];
render_canonical_args(Args) when is_map(Args) ->
    Pairs = [render_canonical_arg(Key, Value)
             || {Key, Value} <- maps:to_list(Args)],
    case Pairs of
        [] ->
            "(args)";
        _ ->
            ["(args ", lists:join(" ", Pairs), ")"]
    end.

render_canonical_arg(Key, {from_step, Id}) ->
    ["(", render_canonical_symbol(Key), " (from_step ",
     render_canonical_value(Id), "))"];
render_canonical_arg(Key, Value) ->
    ["(", render_canonical_symbol(Key), " ",
     render_canonical_value(Value), ")"].

render_canonical_value(Atom) when is_atom(Atom) ->
    render_canonical_symbol(Atom);
render_canonical_value(List) when is_list(List) ->
    ["(", lists:join(" ", [render_canonical_value(Value) || Value <- List]), ")"];
render_canonical_value(Value) ->
    render(Value).

%% Canonical identifiers carry two spellings: symbols (atoms) render bare,
%% and string/fresh-symbol identifiers (binaries) render as strings, which
%% recompile to the same binary — the round trip holds for both.
render_canonical_symbol(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
render_canonical_symbol(Bin) when is_binary(Bin) ->
    render_binary(Bin).

%% A result map is marked by a `status' whose value is one of the terminal
%% statuses the CLI emits. The completed case keeps its fixed
%% `status outputs correlation-id' order; the failed case omits `outputs', emits
%% `(error ...)' in its place, and carries `correlation-id' only when present.
%% A payload-less terminal map (a timed-out or cancelled run carries neither
%% `outputs' nor `error') is still a result map -- it renders as
%% `(result (status timeout) ...)' so the reply stays a recognizable terminal
%% result rather than a headless pair list. Event maps are classified first
%% because an event such as `explore.round.completed' can itself carry a
%% terminal-looking status. The whitelist keeps a `#{status => running}'
%% registry map from being wrongly headed `result'.
is_result_map(Map) ->
    case maps:find(status, Map) of
        {ok, Status} -> is_terminal_status(Status);
        error -> false
    end.

is_terminal_status(completed) -> true;
is_terminal_status(failed) -> true;
is_terminal_status(timeout) -> true;
is_terminal_status(cancelled) -> true;
is_terminal_status(rejected) -> true;
is_terminal_status(error) -> true;
is_terminal_status(_) -> false.

%% The result sub-forms, in order: status, then task-id/run-id if present, then
%% outputs if present, then error or reason when present, then correlation-id if
%% present. `task-id' sits after status and before correlation-id so the
%% existing completed-result order (`status outputs correlation-id') stays
%% stable.
result_pairs(Map) ->
    [render_pair(status, maps:get(status, Map))]
        ++ [render_pair(task_id, V) || {ok, V} <- [maps:find(task_id, Map)]]
        ++ [render_pair(run_id, V) || {ok, V} <- [maps:find(run_id, Map)]]
        ++ [render_pair(outputs, V) || {ok, V} <- [maps:find(outputs, Map)]]
        ++ [render_pair(error, V) || {ok, V} <- [maps:find(error, Map)]]
        ++ [render_pair(reason, V) || {ok, V} <- [maps:find(reason, Map)]]
        ++ [render_pair(correlation_id, V)
            || {ok, V} <- [maps:find(correlation_id, Map)]].

render_symbol(Atom) when is_atom(Atom) ->
    %% `_' in the atom maps back to `-' in the Lisp symbol text.
    string:replace(atom_to_list(Atom), "_", "-", all).

render_string(Bin) when is_binary(Bin) ->
    ["\"", escape(Bin), "\""].

%% Erlang binaries carry bytes, not an intrinsic text encoding. Preserve the
%% established string form when those bytes are valid UTF-8; otherwise emit a
%% typed, ASCII-only form that a Lisp reader can parse and a client can decode
%% without loss. binary:encode_hex/1 is deterministic uppercase hexadecimal.
render_binary(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Utf8 when is_binary(Utf8) ->
            render_string(Utf8);
        _InvalidUtf8 ->
            ["(bytes (hex \"", binary:encode_hex(Bin), "\"))"]
    end.

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
