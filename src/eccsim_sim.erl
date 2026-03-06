-module(eccsim_sim).

-moduledoc "Per-account simulation worker.
Started as a child of eccsim_sup. Wraps one etiq simulation,
runs it immediately, and stores the result for retrieval via await/2.".

-behaviour(gen_server).

-export([start_link/1, await/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("eccsim.hrl").
-include_lib("etiq/include/etiq.hrl").

-type state() :: #{
    sim_pid := pid() | undefined,
    result := {ok, eccsim_ms_handler:ms_state()} | undefined,
    waiters := [gen_server:from()]
}.

-opaque args() :: map().
-export_type([args/0]).

-spec start_link(args()) -> gen_server:start_ret().
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec await(pid(), timeout()) -> {ok, eccsim_ms_handler:ms_state()}.
await(Pid, Timeout) ->
    gen_server:call(Pid, await, Timeout).

-spec init(args()) -> {ok, state()}.
init(#{sim_config := SimConfig, seed_events := SeedEvents}) ->
    {ok, SimPid} = etiq_sup:start_sim(SimConfig),
    ok = etiq_gen:schedule(SimPid, SeedEvents),
    Self = self(),
    spawn_link(fun() ->
        {ok, FinalState} = etiq_gen:run(SimPid),
        gen_server:cast(Self, {sim_done, FinalState})
    end),
    {ok, #{sim_pid => SimPid, result => undefined, waiters => []}}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, term(), state()} | {noreply, state()}.
handle_call(await, _From, #{result := {ok, _} = Result} = State) ->
    {reply, Result, State};
handle_call(await, From, #{result := undefined, waiters := Waiters} = State) ->
    {noreply, State#{waiters := [From | Waiters]}};
handle_call(Request, _From, State) ->
    logger:warning("eccsim_sim: unexpected call ~p", [Request]),
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({sim_done, FinalState}, #{sim_pid := SimPid, waiters := Waiters} = State) ->
    Result = {ok, FinalState},
    lists:foreach(fun(Waiter) -> gen_server:reply(Waiter, Result) end, Waiters),
    etiq_sup:stop_sim(SimPid),
    {noreply, State#{result := Result, waiters := [], sim_pid := undefined}}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(Info, State) ->
    logger:warning("eccsim_sim: unexpected info ~p", [Info]),
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{sim_pid := undefined}) ->
    ok;
terminate(_Reason, #{sim_pid := SimPid}) ->
    etiq_sup:stop_sim(SimPid).
