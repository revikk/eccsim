# eccsim

Erlang Call Center Simulator built on top of the [etiq](https://github.com/revikk/etiq) discrete event simulation library.

Simulates multi-account, multi-skill call centers with typed calls, skilled agents, and pluggable routing strategies. Produces per-account and aggregate performance metrics.

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

The single entry point is `eccsim:run/1`. It returns `{ok, Results}`.

Start an interactive shell with `rebar3 shell` (auto-starts the application).

### Basic example

```erlang
{ok, Results} = eccsim:run(#{
    accounts => #{
        account1 => #{
            call_types => #{
                billing => #{lambda => 5.0, mu => 2.0},
                tech    => #{lambda => 3.0, mu => 1.5}
            },
            agent_groups => [
                #{id => billing_team, count => 4, skills => [billing]},
                #{id => generalists,  count => 2, skills => [billing, tech],
                  priority => [billing, tech]}
            ]
        }
    },
    routing  => longest_idle,
    max_time => 10000,
    seed     => {1, 2, 3}   %% optional, for reproducibility
}).

#{per_account := PerAccount, aggregate := Aggregate} = Results.
#{per_type := PerType, aggregate := AcctAgg} = maps:get(account1, PerAccount).
```

### Config keys

| Key | Required | Description |
|-----|----------|-------------|
| `accounts` | yes | Map of account ID → account config |
| `routing` | yes | Routing strategy atom (e.g. `longest_idle`) |
| `max_time` | yes | Simulation end time (time units) |
| `seed` | no | `{S1, S2, S3}` integer tuple for reproducibility |
| `interval` | no | Snapshot interval for time-series output |
| `output_dir` | no | Directory path for CSV export; omit to skip CSV |

Each **account config**:

| Key | Description |
|-----|-------------|
| `call_types` | Map of type name → `#{lambda := float(), mu := float()}` |
| `agent_groups` | List of `#{id, count, skills}` maps; optional `priority` list |

### Result shapes

**Per-type results** (one per call type per account):

| Field | Description |
|-------|-------------|
| `total_calls` | Number of completed calls of this type |
| `mean_wait_time` | Mean time spent waiting in queue |
| `mean_service_time` | Mean service duration |
| `mean_system_time` | Mean total time (wait + service) |
| `mean_queue_length` | Time-average queue length (Little's Law: Lq = λ·Wq) |
| `offered_load` | Total busy-time for this type / simulation time (dimensionless load) |

**Aggregate results** (per account and overall):

| Field | Description |
|-------|-------------|
| `total_calls` | Total completed calls |
| `mean_wait_time` | Weighted mean wait time across all types |
| `mean_service_time` | Weighted mean service time |
| `mean_system_time` | Weighted mean system time |
| `mean_queue_length` | Sum of per-type time-average queue lengths |
| `mean_system_length` | Time-average total occupancy (queue + in-service) |
| `agent_utilization` | Fraction of total agent capacity in use (0–1) |

### Time-series output

Add `interval` and `output_dir` to collect periodic snapshots exported as CSV:

```erlang
{ok, _Results} = eccsim:run(#{
    accounts => #{...},
    routing  => longest_idle,
    max_time => 10000,
    interval => 100,
    output_dir => "./output"
}).
%% Writes: ./output/eccsim_metrics.csv
```

CSV columns: `time, account, call_type, arrivals, completions, mean_wait_time, mean_service_time, queue_length, in_service, agent_utilization`

Each snapshot row covers one interval bucket. `call_type` is a type name or `aggregate`.

## Architecture

`eccsim_app` (application) → `eccsim_sup` (supervisor). Simulation processes are started dynamically via `etiq_sup`.

| Module | Role |
|--------|------|
| `eccsim` | Public API — orchestrates multi-account simulations |
| `eccsim_ms_handler` | `etiq_handler` for multi-skill simulation events |
| `eccsim_router` | Behaviour definition for pluggable routing strategies |
| `eccsim_router_longest_idle` | Longest-idle-agent routing implementation |
| `eccsim_ms_metrics` | Time-series metrics builder and CSV export |

## License

MIT
