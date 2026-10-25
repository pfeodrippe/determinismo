;; SPDX-License-Identifier: MIT
(ns probe.middleware
  "Data on every eval's final response, through clojure-cli.repl's own helper: the test program
  checks it is there (`probe/evals`, a count of evaluations seen)."
  (:require [clojure-cli.repl.middleware :as mw]))

(def evals (atom 0))

(def middleware
  (mw/assoc-response (fn [] {:probe/evals (swap! evals inc)})))
