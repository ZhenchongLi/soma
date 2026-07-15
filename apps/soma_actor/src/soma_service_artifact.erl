%% @doc Result presentation boundary for service-owned successful outputs.
-module(soma_service_artifact).

-include_lib("kernel/include/file.hrl").

-define(ARTIFACT_VERSION, <<"soma-service-result-v1">>).

-export([present/4]).

-spec present(binary(), term(), pos_integer(), file:filename_all()) ->
    {ok, term()} | {error, artifact_publish_failed}.
present(TaskId, Output, InlineBytes, DataDir) ->
    Encoded = term_to_binary(Output, [deterministic]),
    case byte_size(Encoded) =< InlineBytes of
        true ->
            {ok, Output};
        false ->
            present_artifact(TaskId, Encoded, InlineBytes, DataDir)
    end.

present_artifact(TaskId, Encoded, InlineBytes, DataDir) ->
    Digest = artifact_digest(TaskId, Encoded),
    ArtifactId = binary:encode_hex(Digest),
    ArtifactDir = filename:join(DataDir, "artifacts"),
    ArtifactPath =
        filename:join(ArtifactDir, binary_to_list(ArtifactId)),
    Descriptor = descriptor(ArtifactId, Encoded, InlineBytes),
    case existing_artifact(ArtifactPath, Encoded) of
        matching ->
            {ok, Descriptor};
        missing ->
            ensure_and_publish(
              ArtifactPath, ArtifactId, Encoded, Descriptor);
        invalid ->
            {error, artifact_publish_failed}
    end.

artifact_digest(TaskId, Encoded) ->
    Identity = term_to_binary(
                 {?ARTIFACT_VERSION, TaskId}, [deterministic]),
    crypto:hash(sha256, [Identity, Encoded]).

descriptor(ArtifactId, Encoded, InlineBytes) ->
    #{artifact => ArtifactId,
      bytes => byte_size(Encoded),
      truncated_inline => binary:part(Encoded, 0, InlineBytes)}.

existing_artifact(ArtifactPath, Encoded) ->
    case file:read_link_info(ArtifactPath) of
        {ok, #file_info{type = regular}} ->
            case file:read_file(ArtifactPath) of
                {ok, Encoded} -> matching;
                {ok, _DifferentBytes} -> invalid;
                {error, _Reason} -> invalid
            end;
        {ok, _NonRegular} ->
            invalid;
        {error, enoent} ->
            missing;
        {error, _Reason} ->
            invalid
    end.

ensure_and_publish(ArtifactPath, ArtifactId, Encoded, Descriptor) ->
    case filelib:ensure_dir(ArtifactPath) of
        ok ->
            publish_if_missing(
              ArtifactPath, ArtifactId, Encoded, Descriptor);
        {error, _Reason} ->
            {error, artifact_publish_failed}
    end.

publish_if_missing(ArtifactPath, ArtifactId, Encoded, Descriptor) ->
    case existing_artifact(ArtifactPath, Encoded) of
        matching ->
            {ok, Descriptor};
        missing ->
            publish_new(ArtifactPath, ArtifactId, Encoded, Descriptor);
        invalid ->
            {error, artifact_publish_failed}
    end.

publish_new(ArtifactPath, ArtifactId, Encoded, Descriptor) ->
    TempPath = temporary_path(ArtifactPath, ArtifactId),
    case file:open(TempPath, [write, binary, raw, exclusive]) of
        {ok, IoDevice} ->
            case write_sync_close(IoDevice, Encoded) of
                ok ->
                    rename_temp(
                      TempPath, ArtifactPath, Encoded, Descriptor);
                error ->
                    _ = file:delete(TempPath),
                    {error, artifact_publish_failed}
            end;
        {error, _Reason} ->
            {error, artifact_publish_failed}
    end.

temporary_path(ArtifactPath, ArtifactId) ->
    Random = binary:encode_hex(crypto:strong_rand_bytes(16)),
    TempName =
        <<".", ArtifactId/binary, ".tmp-", Random/binary>>,
    filename:join(filename:dirname(ArtifactPath), binary_to_list(TempName)).

write_sync_close(IoDevice, Encoded) ->
    case file:write(IoDevice, Encoded) of
        ok ->
            close_after_sync(IoDevice, file:sync(IoDevice));
        {error, _Reason} ->
            _ = file:close(IoDevice),
            error
    end.

close_after_sync(IoDevice, ok) ->
    case file:close(IoDevice) of
        ok -> ok;
        {error, _Reason} -> error
    end;
close_after_sync(IoDevice, {error, _Reason}) ->
    _ = file:close(IoDevice),
    error.

rename_temp(TempPath, ArtifactPath, Encoded, Descriptor) ->
    case file:rename(TempPath, ArtifactPath) of
        ok ->
            {ok, Descriptor};
        {error, _Reason} ->
            _ = file:delete(TempPath),
            case existing_artifact(ArtifactPath, Encoded) of
                matching -> {ok, Descriptor};
                _MissingOrInvalid -> {error, artifact_publish_failed}
            end
    end.
