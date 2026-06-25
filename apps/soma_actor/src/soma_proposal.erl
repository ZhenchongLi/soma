%% soma_proposal validates raw LLM output into a tagged proposal.
%%
%% Pure module, mirroring soma_tool_manifest:normalize/1 and soma_lfe:compile/2:
%% no processes, no events. It branches on the `kind` tag field and checks the
%% required fields for that kind, returning {ok, Proposal} | {error, [Diagnostic]}.
-module(soma_proposal).

-export([normalize/1]).

-type proposal() :: map().
-type diagnostic() :: map().

-spec normalize(map()) -> {ok, proposal()} | {error, [diagnostic()]}.
normalize(#{kind := reply, text := Text}) when is_binary(Text) ->
    {ok, #{kind => reply, text => Text}}.
