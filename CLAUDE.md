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

## Code Style Constraints (elvis.config)

- Max line length: **120 characters**
- Max function length: **40 lines**
- Max module length: **500 lines**
- Max function arity: **8**
- No debug calls, no nested try-catch
- All compiler warnings are treated as errors (`warnings_as_errors`)
- All exported functions require typespecs (`warn_missing_spec`)
- Requires OTP 27+
