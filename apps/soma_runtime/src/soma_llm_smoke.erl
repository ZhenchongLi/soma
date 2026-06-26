%% @doc Opt-in manual smoke test for the real OpenAI-compatible provider.
%% v0.6.x node B.1, criterion 12. This is deliberately OFF the gate: it opens a
%% real socket and needs a real API key, which `rebar3 eunit' and `rebar3 ct'
%% must never do. It lives in `src/' as a plain module (not `*_test'/`*_SUITE'),
%% so neither test runner picks it up; it is run by hand.
%%
%% Usage:
%%   SOMA_LLM_API_KEY=sk-... rebar3 shell
%%   1> soma_llm_smoke:run().
%%
%% The key comes from the `SOMA_LLM_API_KEY' environment variable. The base_url
%% and model come from config below (the validated SophNet contract). It builds
%% the request through `soma_llm_openai', sends it over the live `httpc' path,
%% and prints the `reply' proposal it gets back.
-module(soma_llm_smoke).

-export([run/0]).

%% SophNet defaults. The base_url and model are config; the key is a secret read
%% from the environment, never hard-coded.
-define(BASE_URL, <<"https://www.sophnet.com/api/open-apis/v1">>).
-define(MODEL, <<"DeepSeek-V3">>).

%% Run one real chat-completions call and print the resulting `reply' proposal.
%% Reads the API key from `SOMA_LLM_API_KEY'; fails loudly if it is unset rather
%% than sending an empty key. Starts `inets'/`ssl' so the live `httpc' path
%% works from a bare shell.
run() ->
    ApiKey = api_key_from_env(),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Config = #{base_url => ?BASE_URL,
               api_key => ApiKey,
               model => ?MODEL,
               messages => [#{role => <<"user">>,
                              content => <<"Say hello in one short sentence.">>}],
               max_tokens => 64},
    Result = soma_llm_openai:chat(Config),
    io:format("reply proposal: ~p~n", [Result]),
    Result.

api_key_from_env() ->
    case os:getenv("SOMA_LLM_API_KEY") of
        false ->
            error({missing_env, "SOMA_LLM_API_KEY"});
        "" ->
            error({missing_env, "SOMA_LLM_API_KEY"});
        Key ->
            list_to_binary(Key)
    end.
