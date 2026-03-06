-module(eccsim_sup).

-moduledoc "Top-level supervisor for eccsim. Manages per-account simulation workers
(eccsim_sim) as simple_one_for_one temporary children.".

-behaviour(supervisor).

-export([start_link/0, start_sim/1, stop_sim/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec start_sim(eccsim_sim:args()) -> {ok, pid()}.
start_sim(Args) ->
    supervisor:start_child(?SERVER, [Args]).

-spec stop_sim(pid()) -> ok.
stop_sim(Pid) ->
    ok = supervisor:terminate_child(?SERVER, Pid).

-spec init(term()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 0,
        period => 1
    },
    ChildSpec = #{
        id => eccsim_sim,
        start => {eccsim_sim, start_link, []},
        restart => temporary,
        shutdown => 10000,
        type => worker,
        modules => [eccsim_sim]
    },
    {ok, {SupFlags, [ChildSpec]}}.
