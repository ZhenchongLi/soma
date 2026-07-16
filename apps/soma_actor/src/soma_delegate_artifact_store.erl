%% @doc Task-scoped storage for complete delegated observation bytes. Handles
%% are opaque and a lookup is always keyed by both task id and handle.
-module(soma_delegate_artifact_store).

-behaviour(gen_server).

-export([start_link/0, put/2, slice/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

put(TaskId, Bytes) when is_binary(TaskId), is_binary(Bytes) ->
    gen_server:call(?MODULE, {put, TaskId, Bytes}).

slice(TaskId, Handle, Offset, RequestedBytes) ->
    gen_server:call(
      ?MODULE, {slice, TaskId, Handle, Offset, RequestedBytes}).

init([]) ->
    {ok, #{artifacts => #{}}}.

handle_call(
  {put, TaskId, Bytes}, _From,
  State = #{artifacts := Artifacts})
  when is_binary(TaskId), is_binary(Bytes) ->
    Handle = mint_handle(TaskId, Artifacts),
    Descriptor = #{handle => Handle, bytes => byte_size(Bytes)},
    {reply, {ok, Descriptor},
     State#{artifacts :=
                maps:put({TaskId, Handle}, Bytes, Artifacts)}};
handle_call(
  {slice, TaskId, Handle, Offset, RequestedBytes}, _From,
  State = #{artifacts := Artifacts})
  when is_binary(TaskId), is_binary(Handle),
       is_integer(Offset), Offset >= 0,
       is_integer(RequestedBytes), RequestedBytes >= 0 ->
    Reply =
        case maps:find({TaskId, Handle}, Artifacts) of
            {ok, Bytes} when Offset =< byte_size(Bytes) ->
                AvailableBytes = byte_size(Bytes) - Offset,
                SliceBytes = min(AvailableBytes, RequestedBytes),
                {ok, binary:part(Bytes, Offset, SliceBytes)};
            {ok, _Bytes} ->
                {error, invalid_artifact_slice};
            error ->
                {error, not_found}
        end,
    {reply, Reply, State};
handle_call({slice, _TaskId, _Handle, _Offset, _RequestedBytes},
            _From, State) ->
    {reply, {error, invalid_artifact_slice}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

mint_handle(TaskId, Artifacts) ->
    Random = binary:encode_hex(crypto:strong_rand_bytes(16)),
    Handle = <<"delegate-artifact-", Random/binary>>,
    case maps:is_key({TaskId, Handle}, Artifacts) of
        true -> mint_handle(TaskId, Artifacts);
        false -> Handle
    end.
