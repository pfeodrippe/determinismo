;; SPDX-License-Identifier: MIT
(ns probe.init
  "clojure-cli.repl's nREPL server listens on loopback only; the test program runs in another
  node. Runs at startup (the config's :init, before the server starts): nREPL's start-server
  binds every interface, nothing else changed."
  (:require [nrepl.server]))

(defn listen-everywhere []
  (alter-var-root #'nrepl.server/start-server
                  (fn [start] (fn [& options] (apply start (concat options [:bind "0.0.0.0"]))))))
