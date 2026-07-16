%% @doc Minimal scanner+parser for the constrained LFE DSL.
%%
%% Handles: atoms, double-quoted strings (returned as binaries), integers,
%% and nested parenthesised lists. Does NOT handle: floats, character literals,
%% LFE quoting syntax, or comments. Any unrecognised token produces a diagnostic.
%%
%% Forms come back as Erlang terms: existing atoms are atoms, fresh unquoted
%% symbols are {external_symbol, Binary}, strings are binaries, integers are
%% integers, and lists are lists.
-module(soma_lfe_reader).

-export([read_forms/1, read_forms/2]).

-type diagnostic() :: #{message => binary(), line => non_neg_integer()}.

-spec read_forms(binary()) ->
    {ok, [term()]} | {error, [diagnostic()]}.
read_forms(Source) when is_binary(Source) ->
    read_forms(Source, existing_atoms_only).

-spec read_forms(binary(), create_atoms | existing_atoms_only) ->
    {ok, [term()]} | {error, [diagnostic()]}.
read_forms(Source, AtomMode)
  when is_binary(Source),
       (AtomMode =:= create_atoms orelse
        AtomMode =:= existing_atoms_only) ->
    %% Invalid UTF-8 makes characters_to_list/1 return an error/incomplete
    %% tuple, not a list — a bounded diagnostic, never a scan crash.
    case unicode:characters_to_list(Source) of
        Input when is_list(Input) ->
            case scan(Input, 1, [], AtomMode) of
                {ok, Tokens} ->
                    parse_all_forms(Tokens, []);
                {error, Diags} ->
                    {error, Diags}
            end;
        _ ->
            {error, [#{message => <<"source is not valid UTF-8">>, line => 0}]}
    end.

%%% --- Scanner ---

scan([], _Line, Acc, _AtomMode) ->
    {ok, lists:reverse(Acc)};
scan([$\n | Rest], Line, Acc, AtomMode) ->
    scan(Rest, Line + 1, Acc, AtomMode);
scan([C | Rest], Line, Acc, AtomMode)
  when C =:= $\s; C =:= $\t; C =:= $\r ->
    scan(Rest, Line, Acc, AtomMode);
scan([$( | Rest], Line, Acc, AtomMode) ->
    scan(Rest, Line, [{open_paren, Line} | Acc], AtomMode);
scan([$) | Rest], Line, Acc, AtomMode) ->
    scan(Rest, Line, [{close_paren, Line} | Acc], AtomMode);
scan([$" | Rest], Line, Acc, AtomMode) ->
    scan_string(Rest, Line, [], Acc, AtomMode);
scan([C | Rest], Line, Acc, AtomMode) when C >= $0, C =< $9 ->
    scan_integer(Rest, Line, [C], Acc, AtomMode);
scan([$- | Rest], Line, Acc, AtomMode) ->
    case Rest of
        [D | _] when D >= $0, D =< $9 ->
            scan_integer(Rest, Line, [$-], Acc, AtomMode);
        _ ->
            scan_atom(Rest, Line, [$-], Acc, AtomMode)
    end;
scan([C | Rest], Line, Acc, AtomMode) when C >= $a, C =< $z;
                                            C >= $A, C =< $Z;
                                            C =:= $_; C =:= $!; C =:= $?;
                                            C =:= $+; C =:= $*; C =:= $/;
                                            C =:= $=; C =:= $<; C =:= $>;
                                            C =:= $&; C =:= $^; C =:= $~;
                                            C =:= $@; C =:= $# ->
    scan_atom(Rest, Line, [C], Acc, AtomMode);
scan([C | _Rest], Line, _Acc, _AtomMode) ->
    %% ~tc + characters_to_binary: the unrecognised character may be a code
    %% point above 255, which ~c / iolist_to_binary would crash on.
    {error, [#{message => unicode:characters_to_binary(
                    io_lib:format("unrecognised character: ~tc", [C])),
               line => Line}]}.

scan_string([], Line, _Buf, _Acc, _AtomMode) ->
    {error, [#{message => <<"unterminated string">>, line => Line}]};
scan_string([$\\, $" | Rest], Line, Buf, Acc, AtomMode) ->
    scan_string(Rest, Line, [$" | Buf], Acc, AtomMode);
scan_string([$\\, $\\ | Rest], Line, Buf, Acc, AtomMode) ->
    scan_string(Rest, Line, [$\\ | Buf], Acc, AtomMode);
scan_string([$\\, $n | Rest], Line, Buf, Acc, AtomMode) ->
    scan_string(Rest, Line, [$\n | Buf], Acc, AtomMode);
scan_string([$\n | Rest], Line, Buf, Acc, AtomMode) ->
    scan_string(Rest, Line + 1, [$\n | Buf], Acc, AtomMode);
scan_string([$" | Rest], Line, Buf, Acc, AtomMode) ->
    %% characters_to_binary, not list_to_binary: string content may carry
    %% code points above 255 (an em-dash, an accent, Chinese text).
    Str = unicode:characters_to_binary(lists:reverse(Buf)),
    scan(Rest, Line, [{string, Line, Str} | Acc], AtomMode);
scan_string([C | Rest], Line, Buf, Acc, AtomMode) ->
    scan_string(Rest, Line, [C | Buf], Acc, AtomMode).

scan_integer([C | Rest], Line, Buf, Acc, AtomMode)
  when C >= $0, C =< $9 ->
    scan_integer(Rest, Line, [C | Buf], Acc, AtomMode);
scan_integer(Rest, Line, Buf, Acc, AtomMode) ->
    %% next char must be whitespace, paren, or end — else it's an error token
    N = list_to_integer(lists:reverse(Buf)),
    scan(Rest, Line, [{integer, Line, N} | Acc], AtomMode).

scan_atom([C | Rest], Line, Buf, Acc, AtomMode)
  when C >= $a, C =< $z;
       C >= $A, C =< $Z;
       C >= $0, C =< $9;
       C =:= $_; C =:= $-; C =:= $!;
       C =:= $?; C =:= $+; C =:= $*;
       C =:= $/; C =:= $=; C =:= $<;
       C =:= $>; C =:= $&; C =:= $^;
       C =:= $~; C =:= $@; C =:= $# ->
    scan_atom(Rest, Line, [C | Buf], Acc, AtomMode);
scan_atom(Rest, Line, Buf, Acc, AtomMode) ->
    Name = lists:reverse(Buf),
    case length(Name) > 255 of
        true ->
            {error, [#{message => <<"atom name exceeds maximum length of 255 characters">>,
                       line => Line}]};
        false ->
            %% Both atom modes are total: create_atoms interns, and
            %% existing_atoms_only wraps a fresh spelling as bounded
            %% {external_symbol, _} data for the parser to place in context.
            {ok, Atom} = decode_atom(Name, AtomMode),
            scan(
              Rest, Line,
              [{atom, Line, Atom} | Acc], AtomMode)
    end.

decode_atom(Name, create_atoms) ->
    {ok, list_to_atom(Name)};
decode_atom(Name, existing_atoms_only) ->
    try list_to_existing_atom(Name) of
        Atom -> {ok, Atom}
    catch
        error:badarg ->
            %% Keep the spelling as bounded data so the parser can reject it
            %% in context (for example as unknown_field) without interning it.
            {ok, {external_symbol, list_to_binary(Name)}}
    end.

%%% --- Form parser ---

%% parse_all_forms accumulates top-level forms from a flat token list.
parse_all_forms([], Forms) ->
    {ok, lists:reverse(Forms)};
parse_all_forms(Tokens, Forms) ->
    case parse_form(Tokens) of
        {ok, Form, Rest} ->
            parse_all_forms(Rest, [Form | Forms]);
        {error, Diags} ->
            {error, Diags}
    end.

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
    {error, [#{message => <<"unexpected close parenthesis">>, line => Line}]}.

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
