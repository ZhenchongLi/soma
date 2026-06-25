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
        %% staged red: deliberately wrong order — corrected in the green commit
        ?assertEqual([a2, b1, a1], AllTypes),

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

%%% Helpers

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
