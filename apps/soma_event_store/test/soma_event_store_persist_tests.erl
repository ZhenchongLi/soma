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

%%% Helpers

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
