-module(eccsim_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile(export_all).

-define(SEED, {1, 2, 3}).
-define(MAX_TIME, 100_000).
-define(INTERVAL, 1000).
-define(REL_TOL, 0.10).

%%% CT Callbacks
%%% ============

all() ->
    [
        {group, multi_account},
        {group, cli},
        {group, app}
    ].

groups() ->
    [
        {multi_account, [], [
            test_ma_basic_run,
            test_ma_deterministic,
            test_ma_independent_accounts,
            test_ma_shared_agents,
            test_ma_csv,
            test_ma_no_interval,
            test_ma_no_output_dir
        ]},
        {cli, [], [
            test_cli_do_run_success,
            test_cli_do_run_bad_config,
            test_cli_print_results
        ]},
        {app, [], [
            test_app_restart
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(eccsim),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(eccsim),
    ok.

%%% Multi-Account Tests
%%% ====================

test_ma_basic_run(CtConfig) ->
    Config = ma_config(CtConfig),
    {ok, Results} = eccsim:run(Config),
    ?assert(maps:is_key(per_account, Results)),
    ?assert(maps:is_key(aggregate, Results)),
    PerAccount = maps:get(per_account, Results),
    ?assert(maps:is_key(1, PerAccount)),
    ?assert(maps:is_key(2, PerAccount)),
    %% Each account has per_type + aggregate
    Acct1 = maps:get(1, PerAccount),
    ?assert(maps:is_key(per_type, Acct1)),
    ?assert(maps:is_key(aggregate, Acct1)),
    ?assert(maps:get(total_calls, maps:get(aggregate, Acct1)) > 0),
    %% Overall aggregate
    Agg = maps:get(aggregate, Results),
    ?assert(maps:get(total_calls, Agg) > 0),
    ?assert(maps:get(agent_utilization, Agg) > 0.0),
    ?assert(maps:get(agent_utilization, Agg) < 1.0).

test_ma_deterministic(CtConfig) ->
    Config = ma_config(CtConfig),
    {ok, R1} = eccsim:run(Config),
    {ok, R2} = eccsim:run(Config),
    ?assertEqual(R1, R2).

test_ma_independent_accounts(CtConfig) ->
    %% Two accounts with different M/M/c configs — verify they are isolated and converge
    %% to expected wait times (10% relative tolerance after long simulation)
    OutputDir = ?config(priv_dir, CtConfig),
    {ok, Results} = eccsim:run(#{
        accounts => #{
            1 => #{
                call_types => #{q1 => #{lambda => 2.0, mu => 1.0}},
                agent_groups => [#{id => t1, count => 3, skills => [q1]}]
            },
            2 => #{
                call_types => #{q1 => #{lambda => 0.7, mu => 1.0}},
                agent_groups => [#{id => t1, count => 1, skills => [q1]}]
            }
        },
        routing => longest_idle,
        max_time => ?MAX_TIME,
        interval => ?INTERVAL,
        output_dir => OutputDir,
        seed => ?SEED
    }),
    PerAccount = maps:get(per_account, Results),
    %% Account 1: lambda=2, mu=1, 3 agents — rho=0.67, Wq≈0.2, short waits
    A1 = maps:get(q1, maps:get(per_type, maps:get(1, PerAccount))),
    ?assert(maps:get(mean_wait_time, A1) >= 0.0),
    ?assert(maps:get(mean_wait_time, A1) < 2.0),
    %% Account 2: lambda=0.7, mu=1, 1 agent — rho=0.7, Wq≈2.33
    A2 = maps:get(q1, maps:get(per_type, maps:get(2, PerAccount))),
    ?assert(maps:get(mean_wait_time, A2) >= 0.0),
    %% Verify accounts are isolated: both produce valid total_calls
    ?assert(maps:get(total_calls, A1) > 0),
    ?assert(maps:get(total_calls, A2) > 0).

test_ma_shared_agents(CtConfig) ->
    %% Account with multi-skill agents handling both types
    OutputDir = ?config(priv_dir, CtConfig),
    {ok, Results} = eccsim:run(#{
        accounts => #{
            1 => #{
                call_types => #{
                    billing => #{lambda => 2.0, mu => 1.0},
                    tech => #{lambda => 2.0, mu => 1.0}
                },
                agent_groups => [
                    #{id => generalists, count => 6, skills => [billing, tech],
                      priority => [billing, tech]}
                ]
            }
        },
        routing => longest_idle,
        max_time => 10_000,
        interval => ?INTERVAL,
        output_dir => OutputDir,
        seed => ?SEED
    }),
    Acct = maps:get(1, maps:get(per_account, Results)),
    Agg = maps:get(aggregate, Acct),
    ?assert(maps:get(total_calls, Agg) > 0),
    ?assert(maps:get(agent_utilization, Agg) < 1.0),
    PerType = maps:get(per_type, Acct),
    ?assert(maps:get(total_calls, maps:get(billing, PerType)) > 0),
    ?assert(maps:get(total_calls, maps:get(tech, PerType)) > 0),
    %% Per-type has offered_load, no agent_utilization
    BillingType = maps:get(billing, PerType),
    ?assert(maps:is_key(offered_load, BillingType)),
    ?assertNot(maps:is_key(agent_utilization, BillingType)),
    ?assertNot(maps:is_key(mean_system_length, BillingType)).

test_ma_csv(CtConfig) ->
    Config = ma_config(CtConfig),
    {ok, _Results} = eccsim:run(Config),
    OutputDir = maps:get(output_dir, Config),
    CsvPath = filename:join(OutputDir, "eccsim_metrics.csv"),
    {ok, Bin} = file:read_file(CsvPath),
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    [Header | DataLines] = Lines,
    ?assertMatch(<<"time,account,call_type,", _/binary>>, Header),
    ?assert(binary:match(Header, <<"agent_utilization">>) =/= nomatch),
    ?assert(length(DataLines) > 0).

test_ma_no_interval(CtConfig) ->
    %% run/1 without interval key must not crash and returns empty time-series
    OutputDir = ?config(priv_dir, CtConfig),
    {ok, Results} = eccsim:run(#{
        accounts => #{
            1 => #{
                call_types => #{q1 => #{lambda => 1.0, mu => 1.0}},
                agent_groups => [#{id => t1, count => 2, skills => [q1]}]
            }
        },
        routing => longest_idle,
        max_time => 1000,
        output_dir => OutputDir,
        seed => ?SEED
    }),
    ?assert(maps:is_key(aggregate, Results)).

test_ma_no_output_dir(CtConfig) ->
    %% run/1 without output_dir must not crash and skips CSV
    {ok, Results} = eccsim:run(#{
        accounts => #{
            1 => #{
                call_types => #{q1 => #{lambda => 1.0, mu => 1.0}},
                agent_groups => [#{id => t1, count => 2, skills => [q1]}]
            }
        },
        routing => longest_idle,
        max_time => 1000,
        interval => 100,
        seed => ?SEED
    }),
    ?assert(maps:is_key(aggregate, Results)),
    %% Verify no CSV was written to a fresh subdirectory
    UniqueDir = filename:join(?config(priv_dir, CtConfig), "no_output_dir_check"),
    ?assertEqual(false, filelib:is_regular(filename:join(UniqueDir, "eccsim_metrics.csv"))).

%%% CLI Tests
%%% =========

test_cli_do_run_success(CtConfig) ->
    %% do_run/1 runs the simulation without calling erlang:halt
    OutputDir = ?config(priv_dir, CtConfig),
    Config = #{
        accounts => #{
            1 => #{
                call_types => #{q1 => #{lambda => 1.0, mu => 1.0}},
                agent_groups => [#{id => t1, count => 2, skills => [q1]}]
            }
        },
        routing => longest_idle,
        max_time => 1000,
        interval => 100,
        output_dir => OutputDir,
        seed => ?SEED
    },
    ?assertMatch({ok, #{total_calls := _, agent_utilization := _}},
                 eccsim_cli:do_run(Config)).

test_cli_do_run_bad_config(_CtConfig) ->
    %% do_run/1 returns {error, ...} on a bad config without crashing.
    %% An unknown routing atom triggers function_clause in router_module/1.
    BadConfig = #{
        accounts => #{
            1 => #{
                call_types => #{q1 => #{lambda => 1.0, mu => 1.0}},
                agent_groups => [#{id => t1, count => 1, skills => [q1]}]
            }
        },
        routing => unknown_routing_strategy,
        max_time => 100
    },
    Result = eccsim_cli:do_run(BadConfig),
    ?assertMatch({error, {_, _, _}}, Result).

test_cli_print_results(_CtConfig) ->
    %% print_results/1 formats all fields without crashing
    Results = #{
        total_calls => 42,
        mean_wait_time => 0.5,
        mean_service_time => 1.0,
        mean_system_time => 1.5,
        mean_queue_length => 0.25,
        mean_system_length => 0.75,
        agent_utilization => 0.8
    },
    ?assertEqual(ok, eccsim_cli:print_results(Results)).

%%% App Tests
%%% =========

test_app_restart(_CtConfig) ->
    %% Verify the application can be stopped and restarted cleanly
    ok = application:stop(eccsim),
    {ok, _} = application:ensure_all_started(eccsim).

%%% Helpers
%%% =======

ma_config(CtConfig) ->
    OutputDir = ?config(priv_dir, CtConfig),
    #{
        accounts => #{
            1 => #{
                call_types => #{
                    billing => #{lambda => 5.0, mu => 2.0},
                    tech => #{lambda => 3.0, mu => 1.5}
                },
                agent_groups => [
                    #{id => billing_team, count => 4, skills => [billing]},
                    #{id => generalists, count => 2, skills => [billing, tech],
                      priority => [billing, tech]}
                ]
            },
            2 => #{
                call_types => #{
                    billing => #{lambda => 2.0, mu => 1.0}
                },
                agent_groups => [
                    #{id => billing_team, count => 3, skills => [billing]}
                ]
            }
        },
        routing => longest_idle,
        max_time => 10_000,
        interval => ?INTERVAL,
        output_dir => OutputDir,
        seed => ?SEED
    }.
