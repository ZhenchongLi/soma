%% @doc Result presentation boundary for service-owned successful outputs.
-module(soma_service_artifact).

-include_lib("kernel/include/file.hrl").

-define(ARTIFACT_VERSION, <<"soma-service-result-v1">>).

-export([present/4, publish/5]).

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
            publish(
              ArtifactPath, ArtifactId, Encoded, Descriptor,
              fun file:rename/2);
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

-spec publish(
    file:filename_all(), binary(), binary(), map(),
    fun((file:filename_all(), file:filename_all()) ->
        ok | {error, term()})) ->
    {ok, map()} | {error, artifact_publish_failed}.
publish(ArtifactPath, ArtifactId, Encoded, Descriptor, Rename) ->
    case filelib:ensure_dir(ArtifactPath) of
        ok ->
            publish_if_missing(
              ArtifactPath, ArtifactId, Encoded, Descriptor, Rename);
        {error, _Reason} ->
            {error, artifact_publish_failed}
    end.

publish_if_missing(
  ArtifactPath, ArtifactId, Encoded, Descriptor, Rename) ->
    case existing_artifact(ArtifactPath, Encoded) of
        matching ->
            {ok, Descriptor};
        missing ->
            publish_new(
              ArtifactPath, ArtifactId, Encoded, Descriptor, Rename);
        invalid ->
            {error, artifact_publish_failed}
    end.

publish_new(ArtifactPath, ArtifactId, Encoded, Descriptor, Rename) ->
    TempPath = temporary_path(ArtifactPath, ArtifactId),
    case file:open(TempPath, [write, binary, raw, exclusive]) of
        {ok, IoDevice} ->
            case temp_ownership(IoDevice, TempPath) of
                {ok, Ownership} ->
                    write_owned_temp(
                      IoDevice, Ownership, ArtifactPath, Encoded,
                      Descriptor, Rename);
                error ->
                    _ = file:close(IoDevice),
                    {error, artifact_publish_failed}
            end;
        {error, _Reason} ->
            {error, artifact_publish_failed}
    end.

temp_ownership(IoDevice, TempPath) ->
    case file:read_file_info(IoDevice) of
        {ok, #file_info{type = regular} = Info} ->
            {ok, {owned_temp, TempPath, file_identity(Info)}};
        {ok, _NonRegular} ->
            error;
        {error, _Reason} ->
            error
    end.

file_identity(#file_info{
                 major_device = MajorDevice,
                 minor_device = MinorDevice,
                 inode = Inode}) ->
    {MajorDevice, MinorDevice, Inode}.

write_owned_temp(
  IoDevice, Ownership, ArtifactPath, Encoded, Descriptor, Rename) ->
    case write_sync_close(IoDevice, Encoded) of
        ok ->
            rename_temp(
              Ownership, ArtifactPath, Encoded, Descriptor, Rename);
        error ->
            _ = cleanup_owned_temp(Ownership),
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

rename_temp(
  {owned_temp, TempPath, _Identity} = Ownership,
  ArtifactPath, Encoded, Descriptor, Rename) ->
    case Rename(TempPath, ArtifactPath) of
        ok ->
            {ok, Descriptor};
        {error, _Reason} ->
            _ = cleanup_owned_temp(Ownership),
            case existing_artifact(ArtifactPath, Encoded) of
                matching -> {ok, Descriptor};
                _MissingOrInvalid -> {error, artifact_publish_failed}
            end
    end.

cleanup_owned_temp({owned_temp, TempPath, Identity}) ->
    case file:read_link_info(TempPath) of
        {ok, #file_info{type = regular} = Info} ->
            case file_identity(Info) =:= Identity of
                true -> file:delete(TempPath);
                false -> skipped
            end;
        {ok, _NonRegular} ->
            skipped;
        {error, _Reason} ->
            skipped
    end.
