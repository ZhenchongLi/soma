-module(soma_lfe_compile_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1 + 5 — three-step demo compiles to exact step maps.
test_three_step_demo_compiles() ->
    Source = <<
        "(run\n"
        "  (step read file_read\n"
        "    (args (path \"input.txt\") (root \"/tmp\")))\n"
        "  (step process echo\n"
        "    (args (from_step read)))\n"
        "  (step write file_write\n"
        "    (args (path \"output.txt\") (root \"/tmp\") (content (from_step process)))))\n"
    >>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(
        [
            #{id => read,    tool => file_read,  args => #{path => <<"input.txt">>, root => <<"/tmp">>}},
            #{id => process, tool => echo,        args => #{from_step => read}},
            #{id => write,   tool => file_write,  args => #{path => <<"output.txt">>, root => <<"/tmp">>, content => {from_step, process}}}
        ],
        Steps
    ).

three_step_demo_compiles_test() ->
    test_three_step_demo_compiles().

%% Criterion 2 + 5 — bare from_step and field-level from_step compile to runtime shapes.
test_from_step_shapes_compile() ->
    %% bare (from_step Id) — entire args map becomes #{from_step => Id}
    %% s1 precedes s2, so (from_step s1) is a valid back-reference.
    BareSource = <<"(run (step s1 echo (args (message \"hi\"))) (step s2 echo (args (from_step s1))))">>,
    {ok, #{run := #{steps := [_S1, BareStep]}}} = soma_lfe:compile(BareSource, #{}),
    ?assertEqual(
        #{id => s2, tool => echo, args => #{from_step => s1}},
        BareStep
    ),
    %% field-level (Key (from_step Id)) — one arg value is {from_step, Id}
    %% s2 precedes s3, so (from_step s2) is a valid back-reference.
    FieldSource = <<"(run (step s2 echo (args (message \"hi\"))) (step s3 file_write (args (content (from_step s2)) (path \"out.txt\"))))">>,
    {ok, #{run := #{steps := [_S2, FieldStep]}}} = soma_lfe:compile(FieldSource, #{}),
    ?assertEqual(
        #{id => s3, tool => file_write, args => #{content => {from_step, s2}, path => <<"out.txt">>}},
        FieldStep
    ).

from_step_shapes_compile_test() ->
    test_from_step_shapes_compile().

%% Criterion 3 — step without (timeout_ms N) in DSL emits no timeout_ms key.
test_timeout_ms_omitted_when_absent() ->
    Source = <<"(run (step s1 echo (args (message \"hi\"))))">>,
    {ok, #{run := #{steps := [Step]}}} = soma_lfe:compile(Source, #{}),
    ?assertNot(maps:is_key(timeout_ms, Step)).

timeout_ms_omitted_when_absent_test() ->
    test_timeout_ms_omitted_when_absent().

%% Criterion 4 (enhanced) — output satisfies soma_agent_session:start_run/2 contract.
%% Checks is_list(Steps), each step is_map, id and tool are atoms, args is a map.
test_output_satisfies_start_run_contract() ->
    Source = <<
        "(run\n"
        "  (step read file_read (args (path \"in.txt\") (root \"/tmp\")))\n"
        "  (step process echo (args (from_step read)))\n"
        "  (step write file_write (args (path \"out.txt\") (root \"/tmp\") (content (from_step process)))))\n"
    >>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    ?assert(is_list(Steps)),
    lists:foreach(fun(Step) ->
        ?assert(is_map(Step)),
        ?assert(is_atom(maps:get(id, Step))),
        ?assert(is_atom(maps:get(tool, Step))),
        ?assert(is_map(maps:get(args, Step)))
    end, Steps).

output_satisfies_start_run_contract_test() ->
    test_output_satisfies_start_run_contract().

%% Regression — bare from_step trailing after other keys must error, not silently drop prior keys.
test_bare_from_step_trailing_returns_error() ->
    %% (args (path "x") (from_step s2)): path appears before bare from_step.
    %% Before the fix the bare clause discards Acc and returns {ok, #{from_step => s2}},
    %% silently losing path. After the fix it must return {error, _}.
    Source = <<"(run (step s1 echo (args (path \"x\") (from_step s2))))">>,
    ?assertMatch({error, _}, soma_lfe:compile(Source, #{})).

bare_from_step_trailing_returns_error_test() ->
    test_bare_from_step_trailing_returns_error().
