%% @doc Pure repeat-safety classification for normalized tool descriptors.
-module(soma_run_resume_safety).

-export([descriptor_safe/1]).

-spec descriptor_safe(map()) -> boolean().
descriptor_safe(#{effect := Effect, idempotent := Idempotent}) ->
    Effect =:= reader orelse Effect =:= identity orelse Idempotent =:= true;
descriptor_safe(_Descriptor) ->
    false.
