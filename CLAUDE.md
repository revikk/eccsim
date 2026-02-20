# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
rebar3 compile                                          # Build (warnings are errors)
rebar3 lint                                             # Elvis code style check
rebar3 ct                                               # Run all Common Test suites
rebar3 ct --suite=test/my_SUITE                         # Run a specific test suite
rebar3 ct --suite=test/my_SUITE --case=test_name        # Run a single test case
rebar3 shell                                            # Interactive shell (auto-starts app)
```

## Architecture

**eccsim** is an Erlang Call Center Simulator built as a standard OTP application on top of the **etiq** discrete event simulation library.

### OTP Structure

`eccsim_app` (application) → `eccsim_sup` (one_for_one supervisor, currently no children)

Simulation processes are started dynamically via `etiq_sup`.

### Public API

`eccsim:run/1` is the single entry point. It dispatches based on config shape:
- `#{queues := _}` → multi-queue (M/M/c) simulation
- `#{call_types := _}` → multi-skill simulation

Both modes return `{ok, Results}` with stats, and optionally time-series data when an `interval` key is present in the config.

### Simulation Modes

**Multi-queue (M/M/c)** — runs independent parallel M/M/c queues, each driven by `eccsim_handler`. Results include per-queue and aggregate statistics. Validated against analytical Erlang-C formulas.

**Multi-skill** — runs a single simulation with typed calls, skilled agents, and pluggable routing via the `eccsim_router` behaviour. Agents have skill sets and priority orderings. Currently one routing strategy exists: `eccsim_router_longest_idle` (longest-idle-agent first, priority-ordered call selection).

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
| `eccsim` | Public API — dispatches to multi-queue or multi-skill paths |
| `eccsim_handler` | `etiq_handler` for single M/M/c queue events (`customer_arrival`, `service_end`) |
| `eccsim_ms_handler` | `etiq_handler` for multi-skill events (`ms_call_arrival`, `ms_service_end`) |
| `eccsim_router` | Behaviour definition + dispatcher for pluggable routing strategies |
| `eccsim_router_longest_idle` | Longest-idle-agent routing: selects idle agent with matching skill, picks next call by agent priority |
| `eccsim_metrics` | Time-series metrics builder and CSV export for multi-queue results |
| `eccsim_ms_metrics` | Time-series metrics builder and CSV export for multi-skill results |
| `eccsim_stats` | Analytical M/M/c formulas (Erlang-C, utilization, Little's Law) |

### Key Records (`include/eccsim.hrl`)

**Single-queue / multi-queue:**
- `#eccsim_config{lambda, mu, c, max_time}` — per-queue simulation parameters
- `#eccsim_state{}` — full simulation state for one M/M/c queue
- `#call_record{arrival_time, service_start, service_end}` — completed call data
- `#snapshot{time, queue_len, in_service}` — point-in-time state snapshot

**Multi-skill:**
- `#ms_config{call_types, agents, router, max_time}` — multi-skill simulation config
- `#ms_state{}` — full simulation state for multi-skill run
- `#call_type_config{name, lambda, mu}` — arrival/service rates per call type
- `#agent{id, skills, priority, idle_since}` — agent with skill set and priority ordering
- `#ms_call_record{call_type, arrival_time, service_start, service_end, agent_id}` — completed multi-skill call
- `#ms_snapshot{time, queue_lens, in_service}` — per-type queue lengths and in-service counts

## Code Style Constraints (elvis.config)

- Max line length: **120 characters**
- Max function length: **40 lines**
- Max module length: **500 lines**
- Max function arity: **8**
- No debug calls, no nested try-catch
- All compiler warnings are treated as errors (`warnings_as_errors`)
- All exported functions require typespecs (`warn_missing_spec`)
- Requires OTP 27+
