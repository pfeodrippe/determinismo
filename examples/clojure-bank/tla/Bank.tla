---- MODULE Bank ----
\* SPDX-License-Identifier: MIT
\* What the bank promises: a transfer moves an amount between two accounts in one step, and never
\* overdraws. The service's abstract states (its "tla" events) must be a behavior of this spec:
\*   determinismo tla --spec examples/clojure-bank/tla/Bank.tla --events <events of a branch>
EXTENDS Naturals, Sequences

VARIABLE accounts

Accounts == DOMAIN accounts

Transfer(from, to, amount) ==
    /\ from # to
    /\ accounts[from] >= amount
    /\ accounts' = [accounts EXCEPT ![from] = @ - amount, ![to] = @ + amount]

Init == accounts = [account \in 1..10 |-> 100]

Next == \E from, to \in Accounts, amount \in 1..50 : Transfer(from, to, amount)
====
