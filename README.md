# eccsim

Erlang Call Center Simulator built on top of the [etiq](https://github.com/revikk/etiq) discrete event simulation library.

## Prerequisites

- OTP 27+
- rebar3

## Build

```bash
rebar3 compile
```

## Test

```bash
rebar3 ct                                               # Run all tests
rebar3 ct --suite=test/eccsim_SUITE                     # Run the test suite
rebar3 ct --suite=test/eccsim_SUITE --case=test_name    # Run a single test case
rebar3 lint                                             # Code style check
```

## Usage

The single entry point is `eccsim:run/1`. It dispatches based on config shape and returns `{ok, Results}`.

Start an interactive shell with `rebar3 shell` (auto-starts the application).

### Multi-queue (M/M/c)

Runs independent parallel M/M/c queues. Results are validated against analytical Erlang-C formulas.

```erlang
{ok, Results} = eccsim:run(#{
    queues => #{
        billing => #{lambda => 5.0, mu => 2.0, c => 4},
        tech    => #{lambda => 3.0, mu => 1.5, c => 3}
    },
    max_time => 10000,
    seed => {1, 2, 3}          %% optional, for reproducibility
}).

#{per_queue := PerQueue, aggregate := Aggregate} = Results.
#{total_calls := _, mean_wait_time := _, server_utilization := _} = Aggregate.
```

### Multi-skill

Runs a single simulation with typed calls, skilled agents, and pluggable routing.

```erlang
{ok, Results} = eccsim:run(#{
    call_types => #{
        billing => #{lambda => 5.0, mu => 2.0},
        tech    => #{lambda => 3.0, mu => 1.5}
    },
    agent_groups => [
        #{id => billing_team, count => 4, skills => [billing]},
        #{id => generalists,  count => 2, skills => [billing, tech],
          priority => [billing, tech]}
    ],
    routing  => longest_idle,
    max_time => 10000,
    seed     => {1, 2, 3}
}).

#{per_type := PerType, aggregate := Aggregate} = Results.
```

### Time-series metrics

Add an `interval` key to collect periodic snapshots. The result shape changes to include a `time_series` list alongside `results`.

```erlang
{ok, #{results := Results, time_series := TimeSeries}} = eccsim:run(#{
    queues => #{
        billing => #{lambda => 5.0, mu => 2.0, c => 4}
    },
    max_time => 10000,
    interval => 100
}).
```

Export to CSV:

```erlang
%% Multi-queue
Csv = eccsim_metrics:mq_to_csv(TimeSeries),
file:write_file("metrics.csv", Csv).

%% Multi-skill
Csv = eccsim_ms_metrics:to_csv(TimeSeries),
file:write_file("metrics.csv", Csv).
```

## Architecture

`eccsim_app` (application) -> `eccsim_sup` (supervisor). Simulation processes are started dynamically via `etiq_sup`.

| Module | Role |
|--------|------|
| `eccsim` | Public API - dispatches to multi-queue or multi-skill paths |
| `eccsim_handler` | `etiq_handler` for single M/M/c queue |
| `eccsim_ms_handler` | `etiq_handler` for multi-skill simulation |
| `eccsim_router` | Behaviour for pluggable routing strategies |
| `eccsim_router_longest_idle` | Longest-idle-agent routing implementation |
| `eccsim_metrics` | Time-series builder and CSV export (multi-queue) |
| `eccsim_ms_metrics` | Time-series builder and CSV export (multi-skill) |
| `eccsim_stats` | Analytical M/M/c formulas (Erlang-C, Little's Law) |

## License

MIT
