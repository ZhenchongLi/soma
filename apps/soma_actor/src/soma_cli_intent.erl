%% @doc CLI.5 intent escaper. A user intent (e.g. `say "hi"') is rendered into
%% the bytes between the quotes of an `(ask (intent "..."))' s-expr the daemon
%% parses with `soma_lfe'. Any `"' or `\\' in the intent would otherwise close
%% the string early or be misread, so `escape/1' backslash-escapes exactly those
%% two characters -- the inverse of `soma_lfe_reader''s `\\"' -> `"' and
%% `\\\\' -> `\\' rules -- so the daemon reads the original string back intact.
%% No other characters are touched; the wire stays all-Lisp.
-module(soma_cli_intent).

-export([escape/1]).

%% Backslash-escape `"' and `\\' in the intent so it is a valid Lisp string body.
%% `\\' is escaped first by handling each character once, so a literal backslash
%% becomes `\\\\' and a quote becomes `\\"'. Input may be a string or binary;
%% output matches the input's type-friendly iolist usage.
-spec escape(string() | binary()) -> string().
escape(Intent) when is_binary(Intent) ->
    escape(binary_to_list(Intent));
escape(Intent) when is_list(Intent) ->
    lists:flatten([escape_char(C) || C <- Intent]).

escape_char($\\) ->
    [$\\, $\\];
escape_char($") ->
    [$\\, $"];
escape_char(C) ->
    C.
