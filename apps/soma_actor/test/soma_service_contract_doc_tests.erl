-module(soma_service_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTRACT_DOC, "docs/service-contract.md").

%% Issue #246 criterion 11: the published service compatibility matrix must
%% carry every v1 evolution rule and keep its central constants aligned with
%% the production owners.
test_service_contract_defines_compatibility_matrix() ->
    ReadResult = file:read_file(?CONTRACT_DOC),
    ?assertMatch({ok, _}, ReadResult),
    {ok, Doc} = ReadResult,

    VersionRow = matrix_row(Doc, <<"Version negotiation">>),
    SupportedVersions =
        iolist_to_binary(
          io_lib:format(
            "~0p",
            [soma_service_envelope:supported_api_versions()])),
    assert_contains_all(
      VersionRow,
      [<<"current supported set">>,
       SupportedVersions,
       <<"unsupported_api_version">>,
       <<"supported-api-versions">>]),

    RequestFieldsRow = matrix_row(Doc, <<"Request fields">>),
    assert_contains_all(
      RequestFieldsRow,
      [<<"closed under v1">>,
       <<"unknown_field">>,
       <<"must not silently discard">>]),

    ResponseFieldsRow = matrix_row(Doc, <<"Response fields">>),
    assert_contains_all(
      ResponseFieldsRow,
      [<<"additive">>, <<"must ignore unknown response fields">>]),

    StatusRow = matrix_row(Doc, <<"Typed statuses">>),
    assert_contains_all(
      StatusRow,
      [<<"accepted">>, <<"running">>, <<"nonterminal">>,
       <<"succeeded">>, <<"failed">>, <<"rejected">>,
       <<"cancelled">>, <<"in_doubt">>, <<"terminal">>,
       <<"unknown future status is never success">>]),

    ErrorRow = matrix_row(Doc, <<"Typed errors">>),
    assert_contains_all(
      ErrorRow,
      [<<"malformed_request">>, <<"frame_too_large">>,
       <<"response_too_large">>, <<"unsupported_api_version">>,
       <<"invalid_operation">>, <<"request_id_conflict">>,
       <<"not_found">>, <<"not_ready">>, <<"result_unavailable">>,
       <<"invalid_cursor">>, <<"invalid_watch">>, <<"not_running">>,
       <<"artifact_publish_failed">>, <<"internal_error">>,
       <<"RS.1a">>, <<"fixed envelope-validation codes">>]),

    CursorRow = matrix_row(Doc, <<"Cursor resume">>),
    assert_contains_all(
      CursorRow,
      [<<"exclusive">>, <<"first durable event after">>, <<"opaque">>,
       <<"selected task trail">>, <<"reconnect">>,
       <<"does not resend `invoke`">>]),

    SizeRow = matrix_row(Doc, <<"Size limits">>),
    FrameBytes = integer_to_binary(soma_socket_frame:max_bytes()),
    assert_contains_all(
      SizeRow,
      [<<"frame_payload_bytes=", FrameBytes/binary>>,
       <<"terminal_status_summary_bytes=512">>,
       <<"default_inline_result_bytes=16384">>,
       <<"watch_event_payload_bytes=16384">>,
       <<"default_watch_page_events=100">>,
       <<"cursor_input_bytes=4096">>,
       <<"scope_entry_bytes=255">>]),

    SupportRow = matrix_row(Doc, <<"Support and deprecation">>),
    assert_contains_all(
      SupportRow,
      [<<"Adding a supported version does not remove an older version">>,
       <<"deprecated while it still works">>,
       <<"one complete tagged minor release">>,
       <<"only in a later tagged release">>,
       <<"same commit as this matrix and its machine check">>]).

service_contract_defines_compatibility_matrix_test() ->
    test_service_contract_defines_compatibility_matrix().

matrix_row(Doc, Name) ->
    Prefix = <<"| ", Name/binary, " |">>,
    Rows =
        [Line
         || Line <- binary:split(Doc, <<"\n">>, [global]),
            binary:match(Line, Prefix) =:= {0, byte_size(Prefix)}],
    ?assertEqual(1, length(Rows)),
    hd(Rows).

assert_contains_all(Row, Terms) ->
    lists:foreach(
      fun(Term) ->
          ?assertNotEqual(nomatch, binary:match(Row, Term))
      end,
      Terms).
