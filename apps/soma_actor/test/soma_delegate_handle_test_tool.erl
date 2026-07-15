-module(soma_delegate_handle_test_tool).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

describe() ->
    #{name => delegate_handle_test,
      effect => reader,
      idempotent => true,
      timeout_ms => 5000}.

manifest() ->
    (describe())#{adapter => erlang_module,
                  module => ?MODULE}.

invoke(Input = #{handle := OpaqueHandle}, _Ctx) ->
    case whereis(soma_delegate_test_resource_manager) of
        ResourceManagerPid when is_pid(ResourceManagerPid) ->
            ResourceManagerPid !
                {delegate_test_handle_used, self(), Input},
            receive
                {delegate_test_continue, OpaqueHandle} ->
                    {ok, #{handle => OpaqueHandle}}
            after 5000 ->
                {error, handle_access_timeout}
            end;
        undefined ->
            {error, resource_manager_not_running}
    end.
