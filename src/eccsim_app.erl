-module(eccsim_app).

-moduledoc "OTP application callback for eccsim.".

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case eccsim_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        ignore -> {error, ignore};
        {error, _} = Err -> Err
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
