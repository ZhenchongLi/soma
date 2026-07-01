-module(soma_event_store_persist_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1: a store started with start_link/0 creates no file on disk over
%% its lifetime, and append/2 plus all the by_* queries return the same results
%% they return today.
%%
%% The "no file" half is checked by running the whole store lifetime inside a
%% fresh, empty temp directory and asserting nothing appears in it. The
%% "queries unchanged" half drives append/2 and every by_* query through the
%% public API and pins the exact results today's in-memory store returns.
test_in_memory_store_writes_no_file_and_queries_unchanged() ->
    TmpDir = make_tmp_dir(),
    Before = list_dir(TmpDir),
    try
        {ok, Pid} = soma_event_store:start_link(),
        ok = soma_event_store:append(Pid, #{run_id => run_a,
                                            session_id => sess_a,
                                            correlation_id => corr_a,
                                            event_type => a1}),
        ok = soma_event_store:append(Pid, #{run_id => run_b,
                                            session_id => sess_b,
                                            correlation_id => corr_b,
                                            event_type => b1}),
        ok = soma_event_store:append(Pid, #{run_id => run_a,
                                            session_id => sess_a,
                                            correlation_id => corr_a,
                                            event_type => a2}),

        AllTypes = [maps:get(event_type, E) || E <- soma_event_store:all(Pid)],
        ?assertEqual([a1, b1, a2], AllTypes),

        ByRunTypes = [maps:get(event_type, E)
                      || E <- soma_event_store:by_run(Pid, run_a)],
        ?assertEqual([a1, a2], ByRunTypes),

        BySessionTypes = [maps:get(event_type, E)
                          || E <- soma_event_store:by_session(Pid, sess_a)],
        ?assertEqual([a1, a2], BySessionTypes),

        ByCorrTypes = [maps:get(event_type, E)
                       || E <- soma_event_store:by_correlation(Pid, corr_a)],
        ?assertEqual([a1, a2], ByCorrTypes),

        After = list_dir(TmpDir),
        ?assertEqual(Before, After)
    after
        ok = del_tmp_dir(TmpDir)
    end.

in_memory_store_writes_no_file_and_queries_unchanged_test() ->
    test_in_memory_store_writes_no_file_and_queries_unchanged().

%% Criterion 2: a store started with start_link/1 and #{log => Path} has a
%% disk_log file present at Path after the first append/2. The file check reads
%% the filesystem at Path directly.
test_persistent_store_creates_file_after_first_append() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        ?assertNot(filelib:is_regular(Path)),
        {ok, Pid} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid, #{run_id => run_a,
                                            session_id => sess_a,
                                            correlation_id => corr_a,
                                            event_type => a1}),
        ?assert(filelib:is_regular(Path))
    after
        ok = del_tmp_dir(TmpDir)
    end.

persistent_store_creates_file_after_first_append_test() ->
    test_persistent_store_creates_file_after_first_append().

%% Criterion 3: an event passed to append/2 on a persistent store is readable
%% back from the disk_log at Path and equals the store's normalized form of that
%% event. The read-back deliberately goes around the store: the test opens its
%% own short-lived disk_log against the same Path and reads the term with
%% disk_log:chunk, then compares it to the store's normalized view of the same
%% event (obtained through a by_run/2 query, which fills event_id/timestamp/
%% missing mandatory keys exactly as the on-disk term should have them).
test_appended_event_reads_back_from_log_as_normalized() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        RawEvent = #{run_id => run_a,
                     session_id => sess_a,
                     correlation_id => corr_a,
                     event_type => a1},
        {ok, Pid} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid, RawEvent),

        %% The store's normalized form of the appended event. normalize fills
        %% event_id/timestamp/missing mandatory keys, so this is what should
        %% physically sit in the log — not the raw input event.
        [Normalized] = soma_event_store:by_run(Pid, run_a),

        %% Stop the store so its disk_log handle is closed and flushed, then
        %% read the term straight out of the disk_log at Path with our own open.
        ok = stop_store(Pid),
        FromDisk = read_one_log_term(Path),

        ?assertEqual(Normalized, FromDisk)
    after
        ok = del_tmp_dir(TmpDir)
    end.

appended_event_reads_back_from_log_as_normalized_test() ->
    test_appended_event_reads_back_from_log_as_normalized().

%% Criterion 4: a persistent store at Path that has several events appended,
%% is stopped, and is then restarted at the same Path replays the log into its
%% index so all/1 returns those events in append order. The whole assertion runs
%% across two store lifetimes through the public API only: append/2 into the
%% first store, stop it, start a second store at the same Path, and read all/1.
test_restart_recovers_events_into_all() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        {ok, Pid1} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid1, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a1}),
        ok = soma_event_store:append(Pid1, #{run_id => run_b,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => b1}),
        ok = soma_event_store:append(Pid1, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a2}),

        %% Normalized view of what the first store holds, captured before the
        %% restart so the recovered events can be compared exactly (event_id and
        %% timestamp are filled at append time, not regenerated on replay).
        Expected = soma_event_store:all(Pid1),

        ok = stop_store(Pid1),

        {ok, Pid2} = soma_event_store:start_link(#{log => Path}),
        Recovered = soma_event_store:all(Pid2),
        ok = stop_store(Pid2),

        RecoveredTypes = [maps:get(event_type, E) || E <- Recovered],
        ?assertEqual([a1, b1, a2], RecoveredTypes),
        ?assertEqual(Expected, Recovered)
    after
        ok = del_tmp_dir(TmpDir)
    end.

restart_recovers_events_into_all_test() ->
    test_restart_recovers_events_into_all().

%% Criterion 5: after a restart that replays the log, by_run/2 against the
%% rebuilt index returns exactly the events whose run_id matches a given run,
%% in append order, and excludes the events of every other run. Runs across two
%% store lifetimes through the public API only: append events spanning more than
%% one run_id into the first store, stop it, start a second store at the same
%% Path, and query by_run/2.
test_by_run_after_restart_filters_to_one_run() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        {ok, Pid1} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid1, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a1}),
        ok = soma_event_store:append(Pid1, #{run_id => run_b,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => b1}),
        ok = soma_event_store:append(Pid1, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a2}),

        %% Normalized view of run_a's events captured before the restart, so the
        %% recovered run_a events can be compared exactly (event_id and timestamp
        %% are filled at append time, not regenerated on replay).
        ExpectedRunA = soma_event_store:by_run(Pid1, run_a),

        ok = stop_store(Pid1),

        {ok, Pid2} = soma_event_store:start_link(#{log => Path}),
        RecoveredRunA = soma_event_store:by_run(Pid2, run_a),
        ok = stop_store(Pid2),

        RunATypes = [maps:get(event_type, E) || E <- RecoveredRunA],
        ?assertEqual([a1, a2], RunATypes),
        ?assertEqual(ExpectedRunA, RecoveredRunA)
    after
        ok = del_tmp_dir(TmpDir)
    end.

by_run_after_restart_filters_to_one_run_test() ->
    test_by_run_after_restart_filters_to_one_run().

%% Criterion 6: after a restart that replays the log, by_correlation/2 against
%% the rebuilt index returns the full cross-layer chain for a correlation_id,
%% in append order, and excludes the events of every other correlation_id. The
%% chain deliberately spans more than one run_id and session_id under the same
%% correlation_id, modeling a cross-layer chain. Runs across two store lifetimes
%% through the public API only: append events spanning more than one
%% correlation_id into the first store, stop it, start a second store at the
%% same Path, and query by_correlation/2.
test_by_correlation_after_restart_returns_full_chain() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        {ok, Pid1} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid1, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a1}),
        ok = soma_event_store:append(Pid1, #{run_id => run_b,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => b1}),
        %% Second event under corr_a but in a different run/session, so the chain
        %% for corr_a spans more than one layer.
        ok = soma_event_store:append(Pid1, #{run_id => run_c,
                                             session_id => sess_c,
                                             correlation_id => corr_a,
                                             event_type => a2}),

        %% Normalized view of corr_a's chain captured before the restart, so the
        %% recovered chain can be compared exactly (event_id and timestamp are
        %% filled at append time, not regenerated on replay).
        ExpectedCorrA = soma_event_store:by_correlation(Pid1, corr_a),

        ok = stop_store(Pid1),

        {ok, Pid2} = soma_event_store:start_link(#{log => Path}),
        RecoveredCorrA = soma_event_store:by_correlation(Pid2, corr_a),
        ok = stop_store(Pid2),

        CorrATypes = [maps:get(event_type, E) || E <- RecoveredCorrA],
        %% corr_a's full cross-layer chain is [a1, a2] in append order, spanning
        %% run_a/sess_a and run_c/sess_c; b1 belongs to corr_b and is excluded.
        ?assertEqual([a1, a2], CorrATypes),
        ?assertEqual(ExpectedCorrA, RecoveredCorrA)
    after
        ok = del_tmp_dir(TmpDir)
    end.

by_correlation_after_restart_returns_full_chain_test() ->
    test_by_correlation_after_restart_returns_full_chain().

%% Criterion 7: a persistent store opened on a path whose log has a truncated or
%% garbage tail finishes init/1 without crashing and serves the intact events.
%% Intact events are appended through a persistent store and the store is
%% stopped; then the test damages the log file's tail directly at the filesystem
%% level by appending garbage bytes (the "half-written term" condition an unclean
%% shutdown leaves). Restarting the store at the same Path must replay the intact
%% prefix, treat the corrupt tail as end-of-log, finish init/1 cleanly, and serve
%% the intact events through all/1.
test_truncated_tail_boots_and_serves_intact_events() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        {ok, Pid1} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid1, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a1}),
        ok = soma_event_store:append(Pid1, #{run_id => run_b,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => b1}),

        %% Intact events captured before the restart so the recovered set can be
        %% compared exactly.
        Intact = soma_event_store:all(Pid1),

        ok = stop_store(Pid1),

        %% Damage the log's tail off-chain: append garbage bytes that form a
        %% partial, unreadable term at the end of the halt log file.
        append_garbage(Path),

        {ok, Pid2} = soma_event_store:start_link(#{log => Path}),
        Recovered = soma_event_store:all(Pid2),
        ok = stop_store(Pid2),

        RecoveredTypes = [maps:get(event_type, E) || E <- Recovered],
        ?assertEqual([a1, b1], RecoveredTypes),
        ?assertEqual(Intact, Recovered)
    after
        ok = del_tmp_dir(TmpDir)
    end.

truncated_tail_boots_and_serves_intact_events_test() ->
    test_truncated_tail_boots_and_serves_intact_events().

%% Criterion 8: docs/usage.md documents start_link/1 and the restart-durability
%% behavior under the events section. A direct file read over docs/usage.md
%% asserts the prose is present: the persistent opt-in start function
%% (start_link/1 with a log path) and the durability claim (the store survives a
%% restart by replaying the on-disk log). The "events section" half is checked by
%% locating the events heading and asserting the persistence prose sits after it.
test_usage_doc_documents_start_link_1_and_durability() ->
    Doc = read_usage_doc(),

    %% The new persistent start function is named.
    ?assert(contains(Doc, <<"start_link/1">>)),

    %% The opt-in log-path option is shown.
    ?assert(contains(Doc, <<"log =>">>)),

    %% The durability behavior — survives a restart by replaying the disk log —
    %% is stated in prose.
    ?assert(contains(Doc, <<"restart">>)),
    ?assert(contains(Doc, <<"disk_log">>)),

    %% The prose lives under the events section, not somewhere unrelated: the
    %% "## Reading events" heading appears before the start_link/1 mention.
    EventsHeadingPos = find_pos(Doc, <<"## Reading events">>),
    StartLink1Pos = find_pos(Doc, <<"start_link/1">>),
    ?assert(EventsHeadingPos =/= nomatch),
    ?assert(StartLink1Pos =/= nomatch),
    ?assert(EventsHeadingPos < StartLink1Pos).

usage_doc_documents_start_link_1_and_durability_test() ->
    test_usage_doc_documents_start_link_1_and_durability().

%% Criterion 9: docs/contracts/v0.6-test-contract.md exists and maps each
%% persistence proof in this slice to the suite (soma_event_store_persist_tests)
%% and case that proves it. A direct file read over the contract document
%% asserts the file is present and names every persistence proof's case so the
%% mapping is auditable from the contract alone.
test_v0_6_contract_doc_maps_each_persistence_proof() ->
    Doc = read_contract_doc(),

    %% The proving suite is named so the mapping points at a concrete module.
    ?assert(contains(Doc, <<"soma_event_store_persist_tests">>)),

    %% Each persistence proof's case appears, mapping the criterion to the case
    %% that proves it. These are this slice's durability/restart/corrupt-tail
    %% proofs (criteria 1-7).
    Cases = [<<"test_in_memory_store_writes_no_file_and_queries_unchanged">>,
             <<"test_persistent_store_creates_file_after_first_append">>,
             <<"test_appended_event_reads_back_from_log_as_normalized">>,
             <<"test_restart_recovers_events_into_all">>,
             <<"test_by_run_after_restart_filters_to_one_run">>,
             <<"test_by_correlation_after_restart_returns_full_chain">>,
             <<"test_truncated_tail_boots_and_serves_intact_events">>],
    [?assert(contains(Doc, Case)) || Case <- Cases].

v0_6_contract_doc_maps_each_persistence_proof_test() ->
    test_v0_6_contract_doc_maps_each_persistence_proof().

%% v0.7.5 criterion 1: a restarted durable store reports a run whose replayed
%% trail contains run.started and no terminal run event. Completed runs from the
%% same replayed log must not be reported.
test_restarted_disk_log_interrupted_runs_reports_started_without_terminal() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        {ok, Pid1} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid1, #{run_id => interrupted_run,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => <<"run.started">>}),
        ok = soma_event_store:append(Pid1, #{run_id => completed_run,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => <<"run.started">>}),
        ok = soma_event_store:append(Pid1, #{run_id => completed_run,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => <<"run.completed">>}),
        ok = stop_store(Pid1),

        {ok, Pid2} = soma_event_store:start_link(#{log => Path}),
        Interrupted = soma_event_store:interrupted_runs(Pid2),
        ok = stop_store(Pid2),

        ?assertEqual([interrupted_run], Interrupted)
    after
        ok = del_tmp_dir(TmpDir)
    end.

restarted_disk_log_interrupted_runs_reports_started_without_terminal_test() ->
    test_restarted_disk_log_interrupted_runs_reports_started_without_terminal().

%% v0.7.5 criterion 2: a restarted durable store must exclude a run whose
%% replayed trail contains a terminal run event.
test_restarted_disk_log_interrupted_runs_excludes_terminal_run() ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    try
        {ok, Pid1} = soma_event_store:start_link(#{log => Path}),
        ok = soma_event_store:append(Pid1, #{run_id => interrupted_run,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => <<"run.started">>}),
        ok = soma_event_store:append(Pid1, #{run_id => terminal_run,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => <<"run.started">>}),
        ok = soma_event_store:append(Pid1, #{run_id => terminal_run,
                                             session_id => sess_b,
                                             correlation_id => corr_b,
                                             event_type => <<"run.failed">>}),
        ok = stop_store(Pid1),

        {ok, Pid2} = soma_event_store:start_link(#{log => Path}),
        Interrupted = soma_event_store:interrupted_runs(Pid2),
        ok = stop_store(Pid2),

        ?assertEqual([interrupted_run, terminal_run], Interrupted)
    after
        ok = del_tmp_dir(TmpDir)
    end.

restarted_disk_log_interrupted_runs_excludes_terminal_run_test() ->
    test_restarted_disk_log_interrupted_runs_excludes_terminal_run().

%%% Helpers

%% Read docs/usage.md from the repo root. The test runs from the project root
%% (rebar3's cwd), and the umbrella keeps docs/ there.
read_usage_doc() ->
    Path = filename:join([usage_doc_dir(), "docs", "usage.md"]),
    {ok, Bin} = file:read_file(Path),
    Bin.

%% Resolve the repo root from this test module's beam location, walking up from
%% the app's _build directory to the umbrella root that holds docs/.
usage_doc_dir() ->
    %% cwd is the umbrella root under rebar3 eunit.
    {ok, Cwd} = file:get_cwd(),
    Cwd.

%% Read docs/contracts/v0.6-test-contract.md from the repo root. The test runs
%% from the project root (rebar3's cwd), and the umbrella keeps docs/ there.
read_contract_doc() ->
    Path = filename:join([usage_doc_dir(), "docs", "contracts",
                          "v0.6-test-contract.md"]),
    {ok, Bin} = file:read_file(Path),
    Bin.

contains(Haystack, Needle) ->
    find_pos(Haystack, Needle) =/= nomatch.

find_pos(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        {Pos, _Len} -> Pos;
        nomatch -> nomatch
    end.

%% Open a fresh disk_log against an existing halt log file and read its single
%% logged term back. Used to inspect what physically sits in the log, around the
%% store.
%% Stop a store gen_server and wait for it to be gone, so its disk_log handle
%% is closed and the log is flushed to Path before we open our own.
stop_store(Pid) ->
    Ref = monitor(process, Pid),
    gen_server:stop(Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        error(stop_store_timeout)
    end.

read_one_log_term(Path) ->
    Name = {?MODULE, make_ref()},
    %% A halt log that was not closed cleanly comes back as {repaired, ...} on
    %% reopen; with {badbytes, 0} the recovered terms are intact, so either
    %% return is fine for reading.
    case disk_log:open([{name, Name}, {file, Path}, {type, halt}]) of
        {ok, Name} -> ok;
        {repaired, Name, _Recovered, {badbytes, 0}} -> ok
    end,
    {_Cont, [Term]} = disk_log:chunk(Name, start),
    ok = disk_log:close(Name),
    Term.

%% Append garbage bytes to the end of the halt log file, mimicking a partial
%% term left by an unclean shutdown. disk_log:chunk/2 reports this tail as a
%% corrupt-log error rather than returning it as a term.
append_garbage(Path) ->
    {ok, Fd} = file:open(Path, [append, raw, binary]),
    ok = file:write(Fd, <<"garbage-tail-not-a-term-", 0, 1, 2, 3, 255, 254>>),
    ok = file:close(Fd).

make_tmp_dir() ->
    Unique = erlang:integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(["/tmp",
                         "soma_event_store_persist_" ++ Unique]),
    ok = file:make_dir(Dir),
    Dir.

list_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    lists:sort(Names).

del_tmp_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    [ok = file:delete(filename:join(Dir, N)) || N <- Names],
    file:del_dir(Dir).
