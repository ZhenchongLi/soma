%% @doc Actor-layer stable-name registry.
-module(soma_actor_registry).

-behaviour(gen_server).

-export([start_link/0, register/2, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(StableName, Pid) when is_binary(StableName), is_pid(Pid) ->
    gen_server:call(?MODULE, {register, StableName, Pid}).

lookup(StableName) when is_binary(StableName) ->
    gen_server:call(?MODULE, {lookup, StableName}).

init([]) ->
    {ok, #{}}.

handle_call({register, StableName, Pid}, _From, ByName) ->
    {reply, ok, maps:put(StableName, Pid, ByName)};
handle_call({lookup, StableName}, _From, ByName) ->
    Reply = case maps:find(StableName, ByName) of
                {ok, Pid} ->
                    case is_process_alive(Pid) of
                        true -> {ok, Pid};
                        false -> {error, not_found}
                    end;
                error ->
                    {error, not_found}
            end,
    {reply, Reply, ByName}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.
