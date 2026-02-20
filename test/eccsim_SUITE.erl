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
        {group, multi_queue},
        {group, multi_skill}
    ].

groups() ->
    [
        {stats, [parallel], [
            test_utilization,
            test_erlang_c,
            test_wq,
            test_littles_law
        ]},
        {multi_queue, [], [
            test_mq_basic_run,
            test_mq_deterministic,
            test_mq_single_queue,
            test_mq_independent_validation,
            test_mq_metrics,
            test_mq_csv
        ]},
        {multi_skill, [], [
            test_ms_basic_run,
            test_ms_deterministic,
            test_ms_independent_queues,
            test_ms_shared_agents,
            test_ms_metrics,
            test_ms_csv
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
    Pw = eccsim_stats:erlang_c(8.0, 3.0, 3),
    ?assert(abs(Pw - 0.7975) < 0.001).

test_wq(_Config) ->
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

%%% Multi-Queue Tests
%%% =================

test_mq_basic_run(_Config) ->
    {ok, Results} = eccsim:run(mq_config()),
    ?assert(is_map(Results)),
    ?assert(maps:is_key(per_queue, Results)),
    ?assert(maps:is_key(aggregate, Results)),
    Agg = maps:get(aggregate, Results),
    ?assert(maps:get(total_calls, Agg) > 0),
    ?assert(maps:get(server_utilization, Agg) > 0.0),
    ?assert(maps:get(server_utilization, Agg) < 1.0),
    PerQueue = maps:get(per_queue, Results),
    ?assert(maps:is_key(billing, PerQueue)),
    ?assert(maps:is_key(tech, PerQueue)),
    ?assert(maps:get(total_calls, maps:get(billing, PerQueue)) > 0),
    ?assert(maps:get(total_calls, maps:get(tech, PerQueue)) > 0).

test_mq_deterministic(_Config) ->
    Config = mq_config(),
    {ok, R1} = eccsim:run(Config),
    {ok, R2} = eccsim:run(Config),
    ?assertEqual(R1, R2).

test_mq_single_queue(_Config) ->
    %% M/M/1: lambda=0.7, mu=1.0, c=1
    Lambda = 0.7, Mu = 1.0, C = 1,
    {ok, Results} = eccsim:run(#{
        queues => #{q1 => #{lambda => Lambda, mu => Mu, c => C}},
        max_time => ?MAX_TIME,
        seed => ?SEED
    }),
    R = maps:get(q1, maps:get(per_queue, Results)),
    assert_close(maps:get(mean_wait_time, R), eccsim_stats:wq(Lambda, Mu, C), ?REL_TOL),
    assert_close(maps:get(mean_system_time, R), eccsim_stats:w(Lambda, Mu, C), ?REL_TOL),
    assert_close(maps:get(server_utilization, R), eccsim_stats:utilization(Lambda, Mu, C), ?REL_TOL).

test_mq_independent_validation(_Config) ->
    %% Two independent queues, each should match its own M/M/c analytical values
    {ok, Results} = eccsim:run(#{
        queues => #{
            billing => #{lambda => 2.0, mu => 1.0, c => 3},
            tech => #{lambda => 0.7, mu => 1.0, c => 1}
        },
        max_time => ?MAX_TIME,
        seed => ?SEED
    }),
    PerQueue = maps:get(per_queue, Results),
    %% Billing: M/M/3 with lambda=2, mu=1
    BillingR = maps:get(billing, PerQueue),
    assert_close(maps:get(mean_wait_time, BillingR), eccsim_stats:wq(2.0, 1.0, 3), ?REL_TOL),
    assert_close(maps:get(server_utilization, BillingR), eccsim_stats:utilization(2.0, 1.0, 3), ?REL_TOL),
    %% Tech: M/M/1 with lambda=0.7, mu=1
    TechR = maps:get(tech, PerQueue),
    assert_close(maps:get(mean_wait_time, TechR), eccsim_stats:wq(0.7, 1.0, 1), ?REL_TOL),
    assert_close(maps:get(server_utilization, TechR), eccsim_stats:utilization(0.7, 1.0, 1), ?REL_TOL).

test_mq_metrics(_Config) ->
    {ok, #{results := Results, time_series := TS}} = eccsim:run(mq_config_with_interval()),
    ?assert(is_map(Results)),
    ?assert(is_list(TS)),
    ?assert(length(TS) >= 1),
    Keys = [time, queue, arrivals, completions, mean_wait_time,
            mean_service_time, queue_length, system_length, utilization],
    lists:foreach(fun(Point) ->
        lists:foreach(fun(Key) ->
            ?assert(maps:is_key(Key, Point), {missing_key, Key})
        end, Keys)
    end, TS),
    %% Should have aggregate points
    AggPoints = [P || P <- TS, maps:get(queue, P) =:= aggregate],
    ?assert(length(AggPoints) >= 1).

test_mq_csv(_Config) ->
    {ok, #{time_series := TS}} = eccsim:run(mq_config_with_interval()),
    Csv = iolist_to_binary(eccsim_metrics:mq_to_csv(TS)),
    Lines = binary:split(Csv, <<"\n">>, [global, trim_all]),
    ?assertEqual(1 + length(TS), length(Lines)),
    [Header | _] = Lines,
    ?assertMatch(<<"time,queue,", _/binary>>, Header).

%%% Multi-Queue Helpers
%%% ===================

mq_config() ->
    #{
        queues => #{
            billing => #{lambda => 5.0, mu => 2.0, c => 4},
            tech => #{lambda => 3.0, mu => 1.5, c => 3}
        },
        max_time => 10_000,
        seed => ?SEED
    }.

mq_config_with_interval() ->
    (mq_config())#{interval => 1000}.

%%% Multi-Skill Tests
%%% ==================

test_ms_basic_run(_Config) ->
    {ok, Results} = eccsim:run(ms_config()),
    ?assert(is_map(Results)),
    ?assert(maps:is_key(per_type, Results)),
    ?assert(maps:is_key(aggregate, Results)),
    Agg = maps:get(aggregate, Results),
    ?assert(maps:get(total_calls, Agg) > 0),
    ?assert(maps:get(server_utilization, Agg) > 0.0),
    ?assert(maps:get(server_utilization, Agg) < 1.0),
    PerType = maps:get(per_type, Results),
    ?assert(maps:is_key(billing, PerType)),
    ?assert(maps:is_key(tech, PerType)),
    ?assert(maps:get(total_calls, maps:get(billing, PerType)) > 0),
    ?assert(maps:get(total_calls, maps:get(tech, PerType)) > 0).

test_ms_deterministic(_Config) ->
    Config = ms_config(),
    {ok, R1} = eccsim:run(Config),
    {ok, R2} = eccsim:run(Config),
    ?assertEqual(R1, R2).

test_ms_independent_queues(_Config) ->
    %% Two independent queues: billing (lambda=2, mu=1, c=3) and tech (lambda=0.7, mu=1, c=1)
    %% Each agent group handles exactly one type, so results should match M/M/c formulas
    {ok, Results} = eccsim:run(#{
        call_types => #{
            billing => #{lambda => 2.0, mu => 1.0},
            tech => #{lambda => 0.7, mu => 1.0}
        },
        agent_groups => [
            #{id => billing_team, count => 3, skills => [billing]},
            #{id => tech_team, count => 1, skills => [tech]}
        ],
        routing => longest_idle,
        max_time => ?MAX_TIME,
        seed => ?SEED
    }),
    PerType = maps:get(per_type, Results),
    %% Billing: M/M/3 with lambda=2, mu=1 => rho=2/3
    BillingR = maps:get(billing, PerType),
    assert_close(maps:get(mean_wait_time, BillingR), eccsim_stats:wq(2.0, 1.0, 3), ?REL_TOL),
    %% Tech: M/M/1 with lambda=0.7, mu=1 => rho=0.7
    TechR = maps:get(tech, PerType),
    assert_close(maps:get(mean_wait_time, TechR), eccsim_stats:wq(0.7, 1.0, 1), ?REL_TOL).

test_ms_shared_agents(_Config) ->
    %% Generalist agents handle both types, all calls should be served
    {ok, Results} = eccsim:run(#{
        call_types => #{
            billing => #{lambda => 2.0, mu => 1.0},
            tech => #{lambda => 2.0, mu => 1.0}
        },
        agent_groups => [
            #{id => generalists, count => 6, skills => [billing, tech],
              priority => [billing, tech]}
        ],
        routing => longest_idle,
        max_time => 10_000,
        seed => ?SEED
    }),
    Agg = maps:get(aggregate, Results),
    ?assert(maps:get(total_calls, Agg) > 0),
    ?assert(maps:get(server_utilization, Agg) < 1.0),
    PerType = maps:get(per_type, Results),
    ?assert(maps:get(total_calls, maps:get(billing, PerType)) > 0),
    ?assert(maps:get(total_calls, maps:get(tech, PerType)) > 0).

test_ms_metrics(_Config) ->
    {ok, #{results := Results, time_series := TS}} = eccsim:run(ms_config_with_interval()),
    ?assert(is_map(Results)),
    ?assert(is_list(TS)),
    ?assert(length(TS) >= 1),
    %% Each snapshot produces per-type + aggregate points
    Keys = [time, call_type, arrivals, completions, mean_wait_time,
            mean_service_time, queue_length, in_service, utilization],
    lists:foreach(fun(Point) ->
        lists:foreach(fun(Key) ->
            ?assert(maps:is_key(Key, Point), {missing_key, Key})
        end, Keys)
    end, TS),
    %% Should have aggregate points
    AggPoints = [P || P <- TS, maps:get(call_type, P) =:= aggregate],
    ?assert(length(AggPoints) >= 1).

test_ms_csv(_Config) ->
    {ok, #{time_series := TS}} = eccsim:run(ms_config_with_interval()),
    Csv = iolist_to_binary(eccsim_ms_metrics:to_csv(TS)),
    Lines = binary:split(Csv, <<"\n">>, [global, trim_all]),
    ?assertEqual(1 + length(TS), length(Lines)),
    [Header | _] = Lines,
    ?assertMatch(<<"time,call_type,", _/binary>>, Header).

%%% Multi-Skill Helpers
%%% ===================

ms_config() ->
    #{
        call_types => #{
            billing => #{lambda => 5.0, mu => 2.0},
            tech => #{lambda => 3.0, mu => 1.5}
        },
        agent_groups => [
            #{id => billing_team, count => 4, skills => [billing]},
            #{id => generalists, count => 2, skills => [billing, tech],
              priority => [billing, tech]}
        ],
        routing => longest_idle,
        max_time => 10_000,
        seed => ?SEED
    }.

ms_config_with_interval() ->
    (ms_config())#{interval => 1000}.

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
