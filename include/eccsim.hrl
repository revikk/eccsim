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

-record(eccsim_state, {
    config          :: #eccsim_config{},
    queue           :: queue:queue({float(), reference()}),
    queue_len       :: non_neg_integer(),
    in_service      :: #{reference() => {float(), float()}},
    completed       :: [#call_record{}],
    rand_state      :: rand:state(),
    last_event_time :: float(),
    queue_area      :: float(),
    system_area     :: float()
}).

-type eccsim_config() :: #eccsim_config{}.
-type call_record() :: #call_record{}.
-type eccsim_state() :: #eccsim_state{}.

-endif.
