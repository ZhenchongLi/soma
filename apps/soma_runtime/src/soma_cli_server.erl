%% @doc CLI.1 daemon socket server. This slice adds the pure term->JSON shaping
%% layer; the Unix listener, framing, and run handler arrive in later cycles.
%%
%% `encode_response/1' turns a Soma result term into the JSON bytes a client
%% reads. OTP 29's `json:encode/1' already maps atoms and binaries to strings,
%% leaves numbers as numbers, renders lists as arrays, and maps as objects with
%% stringified keys -- exactly the shape this surface needs for plain terms.
-module(soma_cli_server).

-export([encode_response/1]).

%% Encode a Soma result term to JSON bytes. Returns an iolist (the `json'
%% encoder's native output); callers that need a binary wrap with
%% `iolist_to_binary/1'.
%%
%% A reason tuple `{Tag, Detail...}' is shaped to
%% `{"tag":"<Tag>","detail":[<Detail...>]}' so a caller can switch on `tag'
%% without parsing a string; `json:encode/1' has no tuple encoding of its own.
-spec encode_response(term()) -> iolist().
encode_response(Term) when is_tuple(Term), tuple_size(Term) >= 1 ->
    [Tag | Detail] = tuple_to_list(Term),
    json:encode(#{tag => Tag, detail => Detail});
encode_response(Term) ->
    json:encode(Term).
