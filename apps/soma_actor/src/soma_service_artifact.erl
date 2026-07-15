%% @doc Result presentation boundary for service-owned successful outputs.
-module(soma_service_artifact).

-export([present/3]).

-spec present(binary(), term(), pos_integer()) ->
    {ok, term()} | {error, artifact_publish_failed}.
present(_TaskId, Output, InlineBytes) ->
    Encoded = term_to_binary(Output, [deterministic]),
    case byte_size(Encoded) =< InlineBytes of
        true ->
            {ok, Output};
        false ->
            {error, artifact_publish_failed}
    end.
