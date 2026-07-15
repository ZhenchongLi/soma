%% @doc Per-task owner for raw delegate resource leases. Coordinators and
%% disposable round workers receive only the bounded opaque handle projection.
-module(soma_delegate_lease_guard).

-behaviour(gen_statem).

-define(MAX_HANDLE_BYTES, 4096).

-export([start_link/1, handles/1, release_all/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

handles(GuardPid) when is_pid(GuardPid) ->
    gen_statem:call(GuardPid, handles).

release_all(GuardPid) when is_pid(GuardPid) ->
    gen_statem:call(GuardPid, release_all).

init(#{coordinator_pid := CoordinatorPid,
       task_id := TaskId,
       lease_requests := Requests})
  when is_pid(CoordinatorPid), is_binary(TaskId), is_list(Requests) ->
    CoordinatorMRef = erlang:monitor(process, CoordinatorPid),
    case acquire_requests(Requests, #{}, #{}) of
        {ok, Handles, Leases} ->
            {ok, active,
             #{coordinator_pid => CoordinatorPid,
               coordinator_mref => CoordinatorMRef,
               task_id => TaskId,
               handles => Handles,
               leases => Leases}};
        {error, Reason, AcquiredLeases} ->
            release_entries(maps:values(AcquiredLeases)),
            {stop, {lease_acquisition_failed, Reason}}
    end.

callback_mode() ->
    handle_event_function.

handle_event({call, From}, handles, active,
             Data = #{handles := Handles}) ->
    {keep_state, Data, [{reply, From, Handles}]};
handle_event({call, From}, release_all, active,
             Data = #{leases := Leases}) when map_size(Leases) =:= 0 ->
    {keep_state, Data, [{reply, From, ok}]};
handle_event({call, From}, release_all, active,
             Data = #{leases := Leases}) ->
    ClearedData = Data#{leases := #{}},
    {keep_state, ClearedData,
     [{next_event, internal,
       {release_leases, reply, From, maps:values(Leases)}}]};
handle_event(info,
             {'DOWN', CoordinatorMRef, process, CoordinatorPid, _Reason},
             active,
             Data = #{coordinator_pid := CoordinatorPid,
                      coordinator_mref := CoordinatorMRef,
                      leases := Leases}) ->
    ClearedData = Data#{leases := #{}},
    {keep_state, ClearedData,
     [{next_event, internal,
       {release_leases, stop, maps:values(Leases)}}]};
handle_event(internal, {release_leases, reply, From, Entries}, active,
             Data) ->
    release_entries(Entries),
    {keep_state, Data, [{reply, From, ok}]};
handle_event(internal, {release_leases, stop, Entries}, active, Data) ->
    release_entries(Entries),
    {stop, normal, Data};
handle_event(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.

terminate(_Reason, _StateName, #{leases := Leases}) ->
    release_entries(maps:values(Leases)),
    ok.

acquire_requests([], Handles, Leases) ->
    {ok, Handles, Leases};
%% Lease names are part of the round-snapshot boundary: only bounded
%% binaries may become resource-handle keys, so process-local terms (pids,
%% refs) can never reach a worker through the handles map.
acquire_requests(
  [#{name := Name, adapter := Adapter} = Request | Remaining],
  Handles, Leases)
  when is_binary(Name), byte_size(Name) =< 255, is_atom(Adapter) ->
    Options = maps:get(options, Request, #{}),
    case maps:is_key(Name, Handles) of
        true ->
            {error, duplicate_lease_name, Leases};
        false ->
            acquire_request(
              Name, Adapter, Options, Remaining, Handles, Leases)
    end;
acquire_requests([_InvalidRequest | _Remaining], _Handles, Leases) ->
    {error, invalid_lease_request, Leases};
acquire_requests(_ImproperRequests, _Handles, Leases) ->
    {error, invalid_lease_requests, Leases}.

acquire_request(Name, Adapter, Options, Remaining, Handles, Leases)
  when is_map(Options) ->
    case Adapter:acquire(Name, Options) of
        {ok, {OpaqueHandle, RawLease}} ->
            case valid_opaque_handle(OpaqueHandle) of
                true ->
                    Lease = #{name => Name,
                              adapter => Adapter,
                              options => Options,
                              raw_lease => RawLease},
                    acquire_requests(
                      Remaining,
                      maps:put(Name, OpaqueHandle, Handles),
                      maps:put(Name, Lease, Leases));
                false ->
                    _ = Adapter:release(Name, RawLease, Options),
                    {error, invalid_opaque_handle, Leases}
            end;
        {error, Reason} ->
            {error, Reason, Leases};
        _InvalidResult ->
            {error, invalid_lease_adapter_result, Leases}
    end;
acquire_request(_Name, _Adapter, _Options, _Remaining, _Handles, Leases) ->
    {error, invalid_lease_options, Leases}.

valid_opaque_handle(Handle) ->
    safe_handle_term(Handle) andalso
        byte_size(term_to_binary(Handle, [deterministic])) =<
            ?MAX_HANDLE_BYTES.

safe_handle_term(Term)
  when is_atom(Term); is_binary(Term); is_integer(Term); is_float(Term) ->
    true;
safe_handle_term(List) when is_list(List) ->
    lists:all(fun safe_handle_term/1, List);
safe_handle_term(Tuple) when is_tuple(Tuple) ->
    safe_handle_term(tuple_to_list(Tuple));
safe_handle_term(Map) when is_map(Map) ->
    lists:all(
      fun({Key, Value}) ->
              safe_handle_term(Key) andalso safe_handle_term(Value)
      end,
      maps:to_list(Map));
safe_handle_term(_UnsafeTerm) ->
    false.

release_entries(Entries) ->
    lists:foreach(fun release_entry/1, Entries).

release_entry(#{name := Name,
                adapter := Adapter,
                options := Options,
                raw_lease := RawLease}) ->
    _ = Adapter:release(Name, RawLease, Options),
    ok.
