-module(soma_service_envelope_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #243 criterion 1: the locked tool invoke form must compile through the
%% public Lisp edge and normalize into the exact service-envelope allowlist.
test_valid_tool_invoke_compiles_and_normalizes() ->
    Source =
        <<"(invoke\n"
          "  (api-version \"1\")\n"
          "  (request-id \"request-1\")\n"
          "  (tool (name echo) (args (value \"hello\")))\n"
          "  (scope \"echo\")\n"
          "  (deadline-ms 2000)\n"
          "  (max-output-bytes 4096)\n"
          "  (correlation-id \"correlation-1\")\n"
          "  (artifacts \"artifact-1\"))">>,
    {ok, Candidate} = soma_lfe:compile(Source, #{}),
    {ok, Envelope} = soma_service_envelope:normalize(Candidate),
    Expected =
        #{kind => invoke,
          api_version => <<"1">>,
          request_id => <<"request-1">>,
          operation =>
              #{kind => tool,
                step =>
                    #{id => <<"request-1">>,
                      tool => echo,
                      args => #{value => <<"hello">>}}},
          scope => [<<"echo">>],
          deadline_ms => 2000,
          max_output_bytes => 4096,
          correlation_id => <<"correlation-1">>,
          artifacts => [<<"artifact-1">>]},
    ?assertEqual(Expected, Envelope),
    ?assertEqual(
        lists:sort([kind, api_version, request_id, operation, scope,
                    deadline_ms, max_output_bytes, correlation_id, artifacts]),
        lists:sort(maps:keys(Envelope))
    ).

valid_tool_invoke_compiles_and_normalizes_test() ->
    test_valid_tool_invoke_compiles_and_normalizes().
