-module(soma_delegate_test_lease_adapter).

-export([acquire/2, release/3]).

acquire(Name,
        #{observer := Observer,
          opaque_handle := OpaqueHandle,
          raw_lease := RawLease}) ->
    Observer ! {delegate_test_lease_acquired, self(), Name,
                OpaqueHandle, RawLease},
    {ok, {OpaqueHandle, RawLease}}.

release(Name, RawLease, #{observer := Observer}) ->
    Observer ! {delegate_test_lease_released, self(), Name, RawLease},
    ok.
