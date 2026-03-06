-module(eccsim_cli).

-moduledoc "Escript entry point for eccsim.
Usage: eccsim <config_file> [-o <output_dir>]".

-export([main/1, do_run/1, print_results/1]).

%% Dialyzer: eccsim:config() is opaque, but callers construct it as a plain map
%% (file:consult returns map()). Config is an input type — construction is intended.
-dialyzer([{no_opaque, run/2}, {no_opaque, run_sim/1}]).

-spec main([string()]) -> no_return().
main([ConfigPath]) ->
    run(ConfigPath, #{});
main([ConfigPath, "-o", OutputDir]) ->
    run(ConfigPath, #{output_dir => OutputDir});
main(_) ->
    io:format(standard_error, "Usage: eccsim <config_file> [-o <output_dir>]~n", []),
    erlang:halt(1).

-spec run(string(), map()) -> no_return().
run(ConfigPath, Overrides) ->
    case file:consult(ConfigPath) of
        {ok, [Config0]} when is_map(Config0) ->
            Config = maps:merge(Config0, Overrides),
            {ok, _} = application:ensure_all_started(eccsim),
            run_sim(Config);
        {ok, _} ->
            io:format(standard_error, "Error: config file must contain a single map term~n", []),
            erlang:halt(1);
        {error, Reason} ->
            io:format(standard_error, "Error reading ~s: ~p~n", [ConfigPath, Reason]),
            erlang:halt(1)
    end.

-spec run_sim(eccsim:config()) -> no_return().
run_sim(Config) ->
    case do_run(Config) of
        {ok, Agg} ->
            print_results(Agg),
            erlang:halt(0);
        {error, {Class, Reason, Stack}} ->
            io:format(standard_error, "Simulation failed: ~p:~p~n~p~n",
                      [Class, Reason, Stack]),
            erlang:halt(1)
    end.

-doc "Run the simulation and return aggregate results, or an error tuple.
Does not call erlang:halt/1 — safe to call from tests.".
-spec do_run(eccsim:config()) ->
    {ok, eccsim:results()} | {error, {atom(), term(), erlang:stacktrace()}}.
do_run(Config) ->
    try
        {ok, eccsim:aggregate(eccsim:run(Config))}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

-doc "Print aggregate simulation results to stdout.".
-spec print_results(eccsim:results()) -> ok.
print_results(Agg) ->
    io:format("=== Aggregate Results ===~n"),
    io:format("Total calls:        ~B~n", [maps:get(total_calls, Agg)]),
    io:format("Mean wait time:     ~.4f~n", [maps:get(mean_wait_time, Agg)]),
    io:format("Mean service time:  ~.4f~n", [maps:get(mean_service_time, Agg)]),
    io:format("Mean system time:   ~.4f~n", [maps:get(mean_system_time, Agg)]),
    io:format("Mean queue length:  ~.4f~n", [maps:get(mean_queue_length, Agg)]),
    io:format("Mean system length: ~.4f~n", [maps:get(mean_system_length, Agg)]),
    io:format("Agent utilization:  ~.4f~n", [maps:get(agent_utilization, Agg)]).
