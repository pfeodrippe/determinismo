;; SPDX-License-Identifier: MIT
;; Ten accounts in an atom, one thread per connection, and a lost update: transfer! reads both
;; balances, then writes each account on its own, so a concurrent transfer's write is lost and
;; money appears or disappears.
;; Protocol (one line per connection): "transfer FROM TO AMOUNT" -> "ok", "total" -> "N".
(ns bank
  (:require [clojure.string :as string])
  ;; Determinismo (sdk/java) is in the default package: named directly, not imported.
  (:import [java.net ServerSocket]
           [java.io BufferedReader InputStreamReader PrintWriter]))

(def accounts (atom (into (sorted-map) (for [account (range 10)] [account 100]))))

(defn transfer! [from to amount]
  (let [from-balance (get @accounts from)
        to-balance (get @accounts to)]
    (when (>= from-balance amount)
      (Thread/sleep 2) ; Work between the reads and the writes (a lookup, a log): the window.
      (swap! accounts assoc from (- from-balance amount))
      (swap! accounts assoc to (+ to-balance amount))
      ;; An invariant the service itself checks (it holds even with the bug: no overdraft).
      (Determinismo/always (every? #(>= % 0) (vals @accounts))
                           "balances never go negative" nil))))

(defn total [] (reduce + (vals @accounts)))

(defn handle [socket]
  (with-open [socket socket
              in (BufferedReader. (InputStreamReader. (.getInputStream socket)))
              out (PrintWriter. (.getOutputStream socket) true)]
    (let [[command & numbers] (string/split (or (.readLine in) "") #" ")]
      (case command
        "transfer" (let [[from to amount] (map parse-long numbers)]
                     (transfer! from to amount)
                     (.println out "ok"))
        "total" (.println out (str (total)))
        (.println out "unknown")))))

(let [server (ServerSocket. 7000)]
  (loop []
    (let [socket (.accept server)]
      (future (handle socket)))
    (recur)))
