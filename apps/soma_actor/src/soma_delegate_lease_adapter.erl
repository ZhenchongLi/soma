%% @doc Adapter boundary for one named task-scoped delegate lease.
-module(soma_delegate_lease_adapter).

-callback acquire(Name :: term(), Options :: map()) ->
    {ok, {OpaqueHandle :: term(), RawLease :: term()}} |
    {error, Reason :: term()}.

-callback release(Name :: term(), RawLease :: term(), Options :: map()) ->
    ok.
