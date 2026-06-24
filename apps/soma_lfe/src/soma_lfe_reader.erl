%% @doc Minimal scanner+parser for the constrained LFE DSL.
%%
%% Handles: atoms, double-quoted strings (returned as binaries), integers,
%% and nested parenthesised lists. Does NOT handle: floats, character literals,
%% LFE quoting syntax, or comments. Any unrecognised token produces a diagnostic.
%%
%% Forms come back as Erlang terms: atoms are atoms, strings are binaries,
%% integers are integers, lists are lists.
-module(soma_lfe_reader).

-export([read_forms/1]).

-type diagnostic() :: #{message => binary(), line => non_neg_integer()}.

-spec read_forms(binary()) ->
    {ok, [term()]} | {error, [diagnostic()]}.
read_forms(Source) when is_binary(Source) ->
    Input = unicode:characters_to_list(Source),
    case scan(Input, 1, []) of
        {ok, Tokens} ->
            parse_all_forms(Tokens, [], []);
        {error, Diags} ->
            {error, Diags}
    end.

%%% --- Scanner ---

scan([], _Line, Acc) ->
    {ok, lists:reverse(Acc)};
scan([$\n | Rest], Line, Acc) ->
    scan(Rest, Line + 1, Acc);
scan([C | Rest], Line, Acc) when C =:= $\s; C =:= $\t; C =:= $\r ->
    scan(Rest, Line, Acc);
scan([$( | Rest], Line, Acc) ->
    scan(Rest, Line, [{open_paren, Line} | Acc]);
scan([$) | Rest], Line, Acc) ->
    scan(Rest, Line, [{close_paren, Line} | Acc]);
scan([$" | Rest], Line, Acc) ->
    scan_string(Rest, Line, [], Acc);
scan([C | Rest], Line, Acc) when C >= $0, C =< $9 ->
    scan_integer(Rest, Line, [C], Acc);
scan([$- | Rest], Line, Acc) ->
    case Rest of
        [D | _] when D >= $0, D =< $9 ->
            scan_integer(Rest, Line, [$-], Acc);
        _ ->
            scan_atom(Rest, Line, [$-], Acc)
    end;
scan([C | Rest], Line, Acc) when C >= $a, C =< $z;
                                  C >= $A, C =< $Z;
                                  C =:= $_; C =:= $!; C =:= $?;
                                  C =:= $+; C =:= $*; C =:= $/;
                                  C =:= $=; C =:= $<; C =:= $>;
                                  C =:= $&; C =:= $^; C =:= $~;
                                  C =:= $@; C =:= $# ->
    scan_atom(Rest, Line, [C], Acc);
scan([C | _Rest], Line, _Acc) ->
    {error, [#{message => iolist_to_binary(
                    io_lib:format("unrecognised character: ~c", [C])),
               line => Line}]}.

scan_string([], Line, _Buf, _Acc) ->
    {error, [#{message => <<"unterminated string">>, line => Line}]};
scan_string([$\\, $" | Rest], Line, Buf, Acc) ->
    scan_string(Rest, Line, [$" | Buf], Acc);
scan_string([$\\, $\\ | Rest], Line, Buf, Acc) ->
    scan_string(Rest, Line, [$\\ | Buf], Acc);
scan_string([$\\, $n | Rest], Line, Buf, Acc) ->
    scan_string(Rest, Line, [$\n | Buf], Acc);
scan_string([$\n | Rest], Line, Buf, Acc) ->
    scan_string(Rest, Line + 1, [$\n | Buf], Acc);
scan_string([$" | Rest], Line, Buf, Acc) ->
    Str = list_to_binary(lists:reverse(Buf)),
    scan(Rest, Line, [{string, Line, Str} | Acc]);
scan_string([C | Rest], Line, Buf, Acc) ->
    scan_string(Rest, Line, [C | Buf], Acc).

scan_integer([C | Rest], Line, Buf, Acc) when C >= $0, C =< $9 ->
    scan_integer(Rest, Line, [C | Buf], Acc);
scan_integer(Rest, Line, Buf, Acc) ->
    %% next char must be whitespace, paren, or end — else it's an error token
    N = list_to_integer(lists:reverse(Buf)),
    scan(Rest, Line, [{integer, Line, N} | Acc]).

scan_atom([C | Rest], Line, Buf, Acc) when C >= $a, C =< $z;
                                            C >= $A, C =< $Z;
                                            C >= $0, C =< $9;
                                            C =:= $_; C =:= $-; C =:= $!;
                                            C =:= $?; C =:= $+; C =:= $*;
                                            C =:= $/; C =:= $=; C =:= $<;
                                            C =:= $>; C =:= $&; C =:= $^;
                                            C =:= $~; C =:= $@; C =:= $# ->
    scan_atom(Rest, Line, [C | Buf], Acc);
scan_atom(Rest, Line, Buf, Acc) ->
    Name = lists:reverse(Buf),
    case length(Name) > 255 of
        true ->
            {error, [#{message => <<"atom name exceeds maximum length of 255 characters">>,
                       line => Line}]};
        false ->
            Atom = list_to_atom(Name),
            scan(Rest, Line, [{atom, Line, Atom} | Acc])
    end.

%%% --- Form parser ---

%% parse_all_forms accumulates top-level forms from a flat token list.
parse_all_forms([], Forms, []) ->
    {ok, lists:reverse(Forms)};
parse_all_forms([], _Forms, _Stack) ->
    {error, [#{message => <<"unexpected end of input inside a list">>, line => 0}]};
parse_all_forms(Tokens, Forms, []) ->
    case parse_form(Tokens) of
        {ok, Form, Rest} ->
            parse_all_forms(Rest, [Form | Forms], []);
        {error, Diags} ->
            {error, Diags}
    end;
parse_all_forms(_Tokens, _Forms, _Stack) ->
    {error, [#{message => <<"internal reader error">>, line => 0}]}.

%% parse_form reads exactly one form from the head of the token list.
parse_form([{atom, _Line, Atom} | Rest]) ->
    {ok, Atom, Rest};
parse_form([{integer, _Line, N} | Rest]) ->
    {ok, N, Rest};
parse_form([{string, _Line, Str} | Rest]) ->
    {ok, Str, Rest};
parse_form([{open_paren, _Line} | Rest]) ->
    parse_list(Rest, []);
parse_form([{close_paren, Line} | _Rest]) ->
    {error, [#{message => <<"unexpected close parenthesis">>, line => Line}]};
parse_form([]) ->
    {error, [#{message => <<"unexpected end of input">>, line => 0}]}.

parse_list([{close_paren, _Line} | Rest], Acc) ->
    {ok, lists:reverse(Acc), Rest};
parse_list([], _Acc) ->
    {error, [#{message => <<"unclosed parenthesis">>, line => 0}]};
parse_list(Tokens, Acc) ->
    case parse_form(Tokens) of
        {ok, Elem, Rest} ->
            parse_list(Rest, [Elem | Acc]);
        {error, Diags} ->
            {error, Diags}
    end.
