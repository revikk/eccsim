-module(eccsim_stats).

-export([utilization/3, erlang_c/3, wq/3, w/3, lq/3, l/3]).

-spec utilization(Lambda :: float(), Mu :: float(), C :: pos_integer()) -> float().
utilization(Lambda, Mu, C) ->
    Lambda / (C * Mu).

-spec erlang_c(Lambda :: float(), Mu :: float(), C :: pos_integer()) -> float().
erlang_c(Lambda, Mu, C) ->
    A = Lambda / Mu,
    Rho = A / C,
    {Sum, LastTerm} = erlang_c_sum(A, C),
    Tail = LastTerm / (1.0 - Rho),
    Tail / (Sum + Tail).

-spec wq(Lambda :: float(), Mu :: float(), C :: pos_integer()) -> float().
wq(Lambda, Mu, C) ->
    erlang_c(Lambda, Mu, C) / (C * Mu - Lambda).

-spec w(Lambda :: float(), Mu :: float(), C :: pos_integer()) -> float().
w(Lambda, Mu, C) ->
    wq(Lambda, Mu, C) + 1.0 / Mu.

-spec lq(Lambda :: float(), Mu :: float(), C :: pos_integer()) -> float().
lq(Lambda, Mu, C) ->
    Lambda * wq(Lambda, Mu, C).

-spec l(Lambda :: float(), Mu :: float(), C :: pos_integer()) -> float().
l(Lambda, Mu, C) ->
    Lambda * w(Lambda, Mu, C).

%% Iteratively compute sum_{k=0}^{C-1} A^k/k! and the last term A^C/C!.
%% Uses recurrence: term_k = term_{k-1} * A / k to avoid factorial overflow.
-spec erlang_c_sum(A :: float(), C :: pos_integer()) -> {float(), float()}.
erlang_c_sum(A, C) ->
    erlang_c_sum(A, C, 0, 1.0, 0.0).

-spec erlang_c_sum(float(), pos_integer(), non_neg_integer(), float(), float()) ->
    {float(), float()}.
erlang_c_sum(_A, C, C, Term, Sum) ->
    {Sum, Term};
erlang_c_sum(A, C, K, Term, Sum) ->
    erlang_c_sum(A, C, K + 1, Term * A / (K + 1), Sum + Term).
