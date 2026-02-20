-ifndef(ECCSIM_HRL).
-define(ECCSIM_HRL, true).

-record(eccsim_config, {
    lambda   :: float(),
    mu       :: float(),
    c        :: pos_integer(),
    max_time :: number()
}).

-record(call_record, {
    arrival_time  :: float(),
    service_start :: float(),
    service_end   :: float()
}).

-record(snapshot, {
    time       :: float(),
    queue_len  :: non_neg_integer(),
    in_service :: non_neg_integer()
}).

-record(eccsim_state, {
    config          :: #eccsim_config{},
    queue           :: queue:queue({float(), reference()}),
    queue_len       :: non_neg_integer(),
    in_service      :: #{reference() => {float(), float()}},
    completed       :: [#call_record{}],
    rand_state      :: rand:state(),
    last_event_time :: float(),
    queue_area      :: float(),
    system_area     :: float(),
    interval        :: number() | undefined,
    next_snapshot   :: number() | undefined,
    snapshots       :: [#snapshot{}]
}).

-type eccsim_config() :: #eccsim_config{}.
-type call_record() :: #call_record{}.
-type snapshot() :: #snapshot{}.
-type eccsim_state() :: #eccsim_state{}.

%%% Multi-skill records
%%% ===================

-record(call_type_config, {
    name   :: atom(),
    lambda :: float(),
    mu     :: float()
}).

-record(agent, {
    id         :: term(),
    skills     :: [atom()],
    priority   :: [atom()],
    idle_since :: float() | busy
}).

-record(ms_call_record, {
    call_type     :: atom(),
    arrival_time  :: float(),
    service_start :: float(),
    service_end   :: float(),
    agent_id      :: term()
}).

-record(ms_snapshot, {
    time       :: float(),
    queue_lens :: #{atom() => non_neg_integer()},
    in_service :: #{atom() => non_neg_integer()}
}).

-record(ms_config, {
    call_types :: #{atom() => #call_type_config{}},
    agents     :: [#agent{}],
    router     :: module(),
    max_time   :: number()
}).

-record(ms_state, {
    config          :: #ms_config{},
    queues          :: #{atom() => queue:queue({float(), reference()})},
    queue_lens      :: #{atom() => non_neg_integer()},
    idle_agents     :: [#agent{}],
    busy_agents     :: #{term() => {#agent{}, atom(), float(), float()}},
    completed       :: [#ms_call_record{}],
    rand_state      :: rand:state(),
    last_event_time :: float(),
    queue_areas     :: #{atom() => float()},
    system_area     :: float(),
    interval        :: number() | undefined,
    next_snapshot   :: number() | undefined,
    snapshots       :: [#ms_snapshot{}]
}).

-type call_type_config() :: #call_type_config{}.
-type agent() :: #agent{}.
-type ms_call_record() :: #ms_call_record{}.
-type ms_snapshot() :: #ms_snapshot{}.
-type ms_config() :: #ms_config{}.
-type ms_state() :: #ms_state{}.

-endif.
