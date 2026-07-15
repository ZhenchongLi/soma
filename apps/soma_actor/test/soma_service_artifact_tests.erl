-module(soma_service_artifact_tests).

-include_lib("eunit/include/eunit.hrl").

test_failed_publication_cleans_only_owned_temp() ->
    Root = make_temp_dir(),
    ArtifactDir = filename:join(Root, "artifacts"),
    ArtifactId = <<"owned-artifact">>,
    ArtifactPath =
        filename:join(ArtifactDir, binary_to_list(ArtifactId)),
    UnownedPath = filename:join(ArtifactDir, "unowned.tmp"),
    Encoded = term_to_binary(#{result => <<"complete">>}, [deterministic]),
    Descriptor = #{artifact => ArtifactId, bytes => byte_size(Encoded)},
    Rename =
        fun(TempPath, FinalPath) ->
            self() ! {rename_attempt, TempPath, FinalPath},
            {error, injected_rename_failure}
        end,
    try
        ok = filelib:ensure_dir(ArtifactPath),
        ok = file:write_file(UnownedPath, <<"not-owned">>, [exclusive]),

        Result =
            try soma_service_artifact:publish(
                    ArtifactPath, ArtifactId, Encoded, Descriptor, Rename)
            of
                Value -> Value
            catch
                error:undef -> missing_publication_seam
            end,
        ?assertEqual({error, artifact_publish_failed}, Result),

        TempPath =
            receive
                {rename_attempt, AttemptedTempPath, ArtifactPath} ->
                    AttemptedTempPath
            after 1000 ->
                error(rename_not_attempted)
            end,
        ?assertEqual({error, enoent}, file:read_link_info(TempPath)),
        ?assertEqual({ok, <<"not-owned">>}, file:read_file(UnownedPath))
    after
        _ = file:del_dir_r(Root)
    end.

failed_publication_cleans_only_owned_temp_test() ->
    test_failed_publication_cleans_only_owned_temp().

make_temp_dir() ->
    Base =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Value -> Value
        end,
    Root = filename:join(
             Base,
             "soma-service-artifact-" ++
                 integer_to_list(
                   erlang:unique_integer([positive, monotonic]))),
    ok = file:make_dir(Root),
    Root.
