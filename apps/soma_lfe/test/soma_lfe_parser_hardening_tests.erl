-module(soma_lfe_parser_hardening_tests).

-include_lib("eunit/include/eunit.hrl").

test_external_lisp_symbols_have_zero_atom_count_delta() ->
    ok = code:ensure_modules_loaded(
        [soma_lfe_reader, soma_lfe, soma_lfe_parser]
    ),
    _ = soma_lfe_reader:read_forms(<<"parser_hardening_reader_warmup">>),
    {ok, #{run := #{steps := [#{id := s1, tool := echo}]}}} =
        soma_lfe:compile(<<"(run (step s1 echo))">>, #{}),
    {error, [#{code := invalid_top_level_form}]} =
        soma_lfe:compile(<<"(parser_hardening_unknown_warmup)">>, #{}),
    ?assertEqual(warm, warm),
    _ = erlang:system_info(atom_count),

    Unique = integer_to_binary(
        erlang:unique_integer([positive, monotonic])
    ),
    Prefix = <<"parser_hardening_", Unique/binary, "_">>,
    ReaderSymbol = <<Prefix/binary, "reader_symbol">>,
    FirstStep = <<Prefix/binary, "first_step">>,
    SecondStep = <<Prefix/binary, "second_step">>,
    ToolName = <<Prefix/binary, "tool_name">>,
    ArgKey = <<Prefix/binary, "arg_key">>,
    ArgValue = <<Prefix/binary, "arg_value">>,
    UnknownHead = <<Prefix/binary, "unknown_head">>,
    RunSource =
        <<"(run "
          "(step ", FirstStep/binary, " ", ToolName/binary,
          " (args (", ArgKey/binary, " ", ArgValue/binary, "))) "
          "(step ", SecondStep/binary, " ", ToolName/binary,
          " (args (from_step ", FirstStep/binary, "))))">>,
    Rows =
        [
            {direct_reader,
             fun() -> soma_lfe_reader:read_forms(ReaderSymbol) end,
             {ok, [{external_symbol, ReaderSymbol}]}},
            {accepted_run,
             fun() -> soma_lfe:compile(RunSource, #{}) end,
             {ok,
              #{run =>
                    #{steps =>
                          [#{id => FirstStep,
                             tool => ToolName,
                             args => #{ArgKey => ArgValue}},
                           #{id => SecondStep,
                             tool => ToolName,
                             args => #{from_step => FirstStep}}]}}}},
            {rejected_top_level_head,
             fun() ->
                 soma_lfe:compile(<<"(", UnknownHead/binary, ")">>, #{})
             end,
             {error,
              [#{code => invalid_top_level_form,
                 message =>
                     <<"top-level form must be a list headed by 'run'">>,
                 line => 0}]}}
        ],
    lists:foreach(
        fun({Label, Exercise, Expected}) ->
            AtomCountBefore = erlang:system_info(atom_count),
            Actual = Exercise(),
            ?assertEqual({Label, Expected}, {Label, Actual}),
            ?assertEqual(
                {Label, AtomCountBefore},
                {Label, erlang:system_info(atom_count)}
            )
        end,
        Rows
    ).

external_lisp_symbols_have_zero_atom_count_delta_test() ->
    test_external_lisp_symbols_have_zero_atom_count_delta().

%% Review finding (#235): unknown fresh grammar heads must produce fixed
%% named diagnostics whose bytes do not depend on the rejected symbol's
%% length — a 255-character head yields the same diagnostic as a short one.
test_unknown_grammar_symbols_have_fixed_named_diagnostics() ->
    Short = <<"zzq">>,
    Long = binary:copy(<<"z">>, 255),
    Sources =
        [{msg_field,
          fun(Head) ->
                  <<"(msg (type \"chat\") (payload \"p\") (",
                    Head/binary, " 1))">>
          end},
         {steps_child,
          fun(Head) ->
                  <<"(run-steps (", Head/binary,
                    " (id a) (tool echo) (args)))">>
          end},
         {step_child,
          fun(Head) ->
                  <<"(run-steps (step (id a) (tool echo) (",
                    Head/binary, " 1)))">>
          end},
         {ask_field,
          fun(Head) ->
                  <<"(ask (intent \"do\") (", Head/binary, " 1))">>
          end}],
    lists:foreach(
        fun({Label, Source}) ->
            AtomCountBefore = erlang:system_info(atom_count),
            ShortResult = soma_lfe:compile(Source(Short), #{}),
            LongResult = soma_lfe:compile(Source(Long), #{}),
            ?assertMatch({Label, {error, [#{code := _}]}},
                         {Label, ShortResult}),
            ?assertEqual({Label, ShortResult}, {Label, LongResult}),
            ?assertEqual(
                {Label, AtomCountBefore},
                {Label, erlang:system_info(atom_count)})
        end,
        Sources
    ).

unknown_grammar_symbols_have_fixed_named_diagnostics_test() ->
    test_unknown_grammar_symbols_have_fixed_named_diagnostics().
