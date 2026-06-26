%% @doc Real OpenAI-compatible LLM provider behind the `soma_llm_call' seam.
%% v0.6.x node B.1. `build_request/1' is the pure request-shaping function: it
%% takes a config-plus-opts map and returns the pieces of an HTTP POST (the url,
%% the headers, and the JSON-encoded body) -- it sends nothing. The url is
%% `{base_url}/chat/completions'. The impure `httpc' call and `parse_response/1'
%% are later cycles.
-module(soma_llm_openai).

-export([build_request/1]).

%% Build the pieces of the chat-completions POST from a config map. Pure: it
%% opens no socket. The url is the configured `base_url' with `/chat/completions'
%% appended; the body is `json:encode/1' of a map carrying `model' and
%% `messages'.
build_request(#{base_url := BaseUrl, api_key := ApiKey,
                model := Model, messages := Messages}) ->
    Url = <<BaseUrl/binary, "/chat/completions">>,
    Headers = [{"Authorization", "Bearer " ++ binary_to_list(ApiKey)}],
    Body = iolist_to_binary(json:encode(#{model => Model, messages => Messages})),
    #{url => Url, headers => Headers, body => Body}.
