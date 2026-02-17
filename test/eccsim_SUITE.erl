-module(eccsim_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile(export_all).

-define(SEED, {1, 2, 3}).
-define(MAX_TIME, 100_000).
-define(REL_TOL, 0.10).

%%% CT Callbacks
%%% ============

all() ->
    [
        {group, stats},
        {group, simulation},
        {group, metrics}
    ].

groups() ->
    [
        {stats, [parallel], [
            test_utilization,
            test_erlang_c,
            test_wq,
            test_littles_law
        ]},
        {simulation, [], [
            test_basic_run,
            test_deterministic_seed,
            test_mm1,
            test_mm3,
            test_low_utilization,
            test_many_agents
        ]},
        {metrics, [], [
            test_time_series_basic,
            test_time_series_shape,
            test_time_series_consistency,
            test_csv_export,
            test_no_interval_backward_compat
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(eccsim),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(eccsim),
    ok.

%%% Stats Tests
%%% ===========

test_utilization(_Config) ->
    %% lambda=8, mu=3, c=3 => rho = 8/(3*3) = 0.8889
    Rho = eccsim_stats:utilization(8.0, 3.0, 3),
    ?assert(abs(Rho - 8.0 / 9.0) < 1.0e-10).

test_erlang_c(_Config) ->
    %% Known value for lambda=8, mu=3, c=3
    %% A=8/3, rho=8/9
    %% Manual: sum = 1 + 8/3 + (8/3)^2/2 = 1 + 2.6667 + 3.5556 = 7.2222
    %% term_C = (8/3)^3/6 = 512/162 = 3.1605
    %% tail = 3.1605 / (1 - 8/9) = 3.1605 / 0.1111 = 28.4444
    %% P_wait = 28.4444 / (7.2222 + 28.4444) = 28.4444 / 35.6667 = 0.7975
    Pw = eccsim_stats:erlang_c(8.0, 3.0, 3),
    ?assert(abs(Pw - 0.7975) < 0.001).

test_wq(_Config) ->
    %% Wq = ErlangC / (c*mu - lambda) = 0.7975 / (9 - 8) = 0.7975
    Wq = eccsim_stats:wq(8.0, 3.0, 3),
    ?assert(abs(Wq - 0.7975) < 0.001).

test_littles_law(_Config) ->
    Lambda = 8.0, Mu = 3.0, C = 3,
    Wq = eccsim_stats:wq(Lambda, Mu, C),
    Lq = eccsim_stats:lq(Lambda, Mu, C),
    ?assert(abs(Lq - Lambda * Wq) < 1.0e-10),
    W = eccsim_stats:w(Lambda, Mu, C),
    L = eccsim_stats:l(Lambda, Mu, C),
    ?assert(abs(L - Lambda * W) < 1.0e-10).

%%% Simulation Tests
%%% ================

test_basic_run(_Config) ->
    {ok, Results} = eccsim:run(#{
        lambda => 2.0, mu => 1.0, c => 3,
        max_time => 1000, seed => ?SEED
    }),
    ?assert(is_map(Results)),
    ?assert(maps:get(total_calls, Results) > 0),
    ?assert(maps:get(mean_wait_time, Results) >= 0.0),
    ?assert(maps:get(server_utilization, Results) > 0.0),
    ?assert(maps:get(server_utilization, Results) < 1.0).

test_deterministic_seed(_Config) ->
    Config = #{lambda => 5.0, mu => 2.0, c => 3, max_time => 10_000, seed => ?SEED},
    {ok, R1} = eccsim:run(Config),
    {ok, R2} = eccsim:run(Config),
    ?assertEqual(R1, R2).

test_mm1(_Config) ->
    %% M/M/1: lambda=0.7, mu=1.0, c=1, rho=0.7
    Lambda = 0.7, Mu = 1.0, C = 1,
    {ok, R} = eccsim:run(#{
        lambda => Lambda, mu => Mu, c => C,
        max_time => ?MAX_TIME, seed => ?SEED
    }),
    assert_close(maps:get(mean_wait_time, R), eccsim_stats:wq(Lambda, Mu, C), ?REL_TOL),
    assert_close(maps:get(mean_system_time, R), eccsim_stats:w(Lambda, Mu, C), ?REL_TOL),
    assert_close(maps:get(server_utilization, R), eccsim_stats:utilization(Lambda, Mu, C), ?REL_TOL).

test_mm3(_Config) ->
    %% M/M/3: lambda=8, mu=3, c=3, rho=0.889
    Lambda = 8.0, Mu = 3.0, C = 3,
    {ok, R} = eccsim:run(#{
        lambda => Lambda, mu => Mu, c => C,
        max_time => ?MAX_TIME, seed => ?SEED
    }),
    assert_close(maps:get(mean_wait_time, R), eccsim_stats:wq(Lambda, Mu, C), ?REL_TOL),
    assert_close(maps:get(mean_system_time, R), eccsim_stats:w(Lambda, Mu, C), ?REL_TOL),
    assert_close(maps:get(server_utilization, R), eccsim_stats:utilization(Lambda, Mu, C), ?REL_TOL).

test_low_utilization(_Config) ->
    %% rho = 3/(10*1) = 0.3, very little queueing
    Lambda = 3.0, Mu = 1.0, C = 10,
    {ok, R} = eccsim:run(#{
        lambda => Lambda, mu => Mu, c => C,
        max_time => ?MAX_TIME, seed => ?SEED
    }),
    ?assert(maps:get(mean_wait_time, R) < 0.05),
    assert_close(maps:get(server_utilization, R), eccsim_stats:utilization(Lambda, Mu, C), ?REL_TOL).

test_many_agents(_Config) ->
    %% c=20, lambda=2, mu=1 => rho=0.1, effectively no queueing
    Lambda = 2.0, Mu = 1.0, C = 20,
    {ok, R} = eccsim:run(#{
        lambda => Lambda, mu => Mu, c => C,
        max_time => 50_000, seed => ?SEED
    }),
    ?assert(maps:get(mean_wait_time, R) < 0.01),
    assert_close(maps:get(mean_service_time, R), 1.0 / Mu, ?REL_TOL).

%%% Metrics Tests
%%% ==============

test_time_series_basic(_Config) ->
    Interval = 1000,
    MaxTime = 10_000,
    {ok, #{results := Results, time_series := TS}} = eccsim:run(#{
        lambda => 8.0, mu => 3.0, c => 3,
        max_time => MaxTime, seed => ?SEED, interval => Interval
    }),
    ?assert(is_map(Results)),
    ?assert(is_list(TS)),
    ?assert(length(TS) >= 1),
    %% Verify time values are sequential with correct step
    Times = [maps:get(time, P) || P <- TS],
    N = length(TS),
    Expected = [float(I * Interval) || I <- lists:seq(1, N)],
    ?assertEqual(Expected, Times).

test_time_series_shape(_Config) ->
    {ok, #{time_series := TS}} = eccsim:run(#{
        lambda => 2.0, mu => 1.0, c => 3,
        max_time => 5000, seed => ?SEED, interval => 1000
    }),
    Keys = [time, arrivals, completions, mean_wait_time, mean_service_time,
            queue_length, system_length, utilization],
    lists:foreach(fun(Point) ->
        lists:foreach(fun(Key) ->
            ?assert(maps:is_key(Key, Point), {missing_key, Key})
        end, Keys)
    end, TS).

test_time_series_consistency(_Config) ->
    {ok, #{results := R, time_series := TS}} = eccsim:run(#{
        lambda => 8.0, mu => 3.0, c => 3,
        max_time => ?MAX_TIME, seed => ?SEED, interval => 1000
    }),
    TotalCalls = maps:get(total_calls, R),
    TotalCompletions = lists:sum([maps:get(completions, P) || P <- TS]),
    %% Most completions should be covered by time-series buckets
    ?assert(TotalCompletions > 0),
    ?assert(TotalCompletions =< TotalCalls).

test_csv_export(_Config) ->
    {ok, #{time_series := TS}} = eccsim:run(#{
        lambda => 2.0, mu => 1.0, c => 3,
        max_time => 5000, seed => ?SEED, interval => 1000
    }),
    Csv = iolist_to_binary(eccsim_metrics:to_csv(TS)),
    Lines = binary:split(Csv, <<"\n">>, [global, trim_all]),
    %% Header + data rows
    ?assertEqual(1 + length(TS), length(Lines)),
    [Header | _] = Lines,
    ?assertMatch(<<"time,arrivals,completions,", _/binary>>, Header).

test_no_interval_backward_compat(_Config) ->
    {ok, Results} = eccsim:run(#{
        lambda => 2.0, mu => 1.0, c => 3,
        max_time => 1000, seed => ?SEED
    }),
    %% Without interval, returns plain results map (not wrapped)
    ?assert(maps:is_key(total_calls, Results)),
    ?assertNot(maps:is_key(results, Results)),
    ?assertNot(maps:is_key(time_series, Results)).

%%% Helpers
%%% =======

assert_close(Actual, Expected, RelTol) when Expected > 0.001 ->
    RelErr = abs(Actual - Expected) / Expected,
    case RelErr =< RelTol of
        true -> ok;
        false ->
            ct:fail("Expected ~.4f, got ~.4f (relative error ~.2f% > ~.2f%)",
                    [Expected, Actual, RelErr * 100, RelTol * 100])
    end;
assert_close(Actual, _Expected, _RelTol) ->
    %% Near-zero expected: use absolute tolerance
    ?assert(abs(Actual) < 0.05).
