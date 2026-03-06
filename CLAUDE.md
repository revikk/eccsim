# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
rebar3 compile                                          # Build (warnings are errors)
rebar3 lint                                             # Elvis code style check
rebar3 ct                                               # Run all Common Test suites
rebar3 ct --suite=test/eccsim_SUITE                     # Run the test suite
rebar3 ct --suite=test/eccsim_SUITE --case=test_name    # Run a single test case
rebar3 shell                                            # Interactive shell (auto-starts app)
```

## Architecture

**eccsim** is an Erlang Call Center Simulator built as a standard OTP application on top of the **etiq** discrete event simulation library.

### OTP Structure

`eccsim_app` (application) → `eccsim_sup` (one_for_one supervisor, no static children)

Simulation processes are started dynamically via `etiq_sup`.

### Public API

`eccsim:run/1` is the single entry point. Config shape:

```erlang
#{
    accounts  := #{term() => #{
        call_types   := #{atom() => #{lambda := float(), mu := float()}},
        agent_groups := [#{id := term(), count := pos_integer(), skills := [atom()]}]
    }},
    routing   := atom(),     %% e.g. longest_idle
    max_time  := number(),
    interval  => number(),   %% optional: enables time-series snapshots
    output_dir => string(),  %% optional: enables CSV export
    seed      => {integer(), integer(), integer()}  %% optional: for reproducibility
}
```

Returns `{ok, #{per_account := ..., aggregate := ...}}`.

### Simulation Mode

**Multi-skill multi-account**: each account runs an independent simulation with typed calls, skilled agents, and pluggable routing via `eccsim_router`. Accounts run in parallel (one process per account). Each account gets a deterministic seed derived from the base seed.

### etiq Integration

The core simulation engine is `etiq`. To build simulation logic, implement the `etiq_handler` behavior:

```erlang
-behaviour(etiq_handler).
-export([handle_event/3]).

%% Called for each event in simulation time order
handle_event(Event, Clock, State) -> {NewEvents, NewState}.
```

Key records from `etiq.hrl`:
- `#event{time, type, data}` — a simulation event
- `#sim_config{handler, handler_state, max_time}` — simulation configuration

Events are stored in a priority queue (`gb_trees`) keyed by `{Time, Ref}`. The simulation processes events in chronological order, calling the handler for each one. The handler returns new events to schedule and updated state.

### Key Modules

| Module | Role |
|--------|------|
| `eccsim` | Public API — orchestrates parallel multi-account simulations |
| `eccsim_ms_handler` | `etiq_handler` for multi-skill events (`ms_call_arrival`, `ms_service_end`) |
| `eccsim_router` | Behaviour definition + dispatcher for pluggable routing strategies |
| `eccsim_router_longest_idle` | Longest-idle-agent routing: selects idle agent with matching skill, picks next call by agent priority |
| `eccsim_ms_metrics` | Time-series metrics builder and CSV export |

### Key Records (`include/eccsim.hrl`)

- `#ms_config{call_types, agents, router, max_time}` — multi-skill simulation config
- `#ms_state{}` — full simulation state for one account's run
- `#call_type_config{name, lambda, mu}` — arrival/service rates per call type
- `#agent{id, skills, priority, idle_since}` — agent with skill set and priority ordering
- `#ms_call_record{call_type, arrival_time, service_start, service_end, agent_id}` — completed call
- `#ms_snapshot{time, queue_lens, in_service}` — per-type queue lengths and in-service counts at a point in time

### Result Metrics

**Per-type results** — one per call type per account:
- `mean_wait_time`, `mean_service_time`, `mean_system_time` — computed from completed call records
- `mean_queue_length` — time-average via area integral (`queue_areas / max_time`)
- `offered_load` — total busy-time for this type / simulation time; dimensionless load, meaningful when agents are shared across types (no per-type agent count exists in multi-skill)

**Aggregate results** — per account and across all accounts:
- Same time fields, weighted by call count
- `mean_system_length` — time-average total occupancy (`system_area / max_time`), i.e. L from Little's Law
- `agent_utilization` — total service time / (total agents × max_time); fraction of agent capacity used

Note: `eccsim_stats` (M/M/c analytical formulas) has been removed. Those formulas assume dedicated agents per queue and do not apply to multi-skill routing.

### Area Tracking (`eccsim_ms_handler`)

At each event, `update_areas/2` accumulates:
- `queue_areas`: per-type integral of queue length × Δt
- `system_area`: integral of (total queued + total busy) × Δt

Dividing by `max_time` gives time-average lengths (Little's Law).

## Code Style Constraints (elvis.config)

- Max line length: **120 characters**
- Max function length: **40 lines**
- Max module length: **500 lines**
- Max function arity: **8**
- No debug calls, no nested try-catch
- All compiler warnings are treated as errors (`warnings_as_errors`)
- All exported functions require typespecs (`warn_missing_spec`)
- Requires OTP 27+
