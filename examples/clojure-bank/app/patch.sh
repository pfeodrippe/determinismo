#!/bin/sh
# SPDX-License-Identifier: MIT
# The fix, applied to the running service through its socket REPL: transfers become one swap!.
printf '%s\n' "(in-ns 'bank)" \
  "(defn transfer! [from to amount] (swap! accounts (fn [m] (if (>= (get m from) amount) (-> m (update from - amount) (update to + amount)) m))))" \
  ":repl/quit" | nc 127.0.0.1 5555
