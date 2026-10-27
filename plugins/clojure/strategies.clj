#!/usr/bin/env bb
;; SPDX-License-Identifier: MIT
;; Exploration strategies in Clojure, served over TCP to `determinismo explore --strategy
;; tcp://127.0.0.1:<port>` (protocol v1, docs/PLUGINS.md), with an nREPL server: redefine a
;; strategy (or write a new one) from your editor, and the next generation uses it. No rebuild, no
;; restart.
;;
;;   bb plugins/clojure/strategies.clj [--port 9100] [--nrepl 1667] [--control 9101]
;;                                     [--strategy rarity] [--events-dir <explore's --events-dir>]
;;
;; A strategy is a map in `strategies`: `:returns` gets the generation's candidates (each
;; timeline: its span and the behaviors it reached, with how many timelines reached them) and
;; chooses up to `count` moments to branch from, each {:branch :vtime_ns :reason}; nil or [] leaves
;; it to the explorer. `(use-strategy! :rarity)` switches; the control port takes "use <name>" (for
;; scripts: bench/explore.py). Everything seen is kept for the REPL: `@generations` (candidates and
;; choices), `@ends` (each timeline's outcome and failing properties), and `(timeline n)` reads a
;; whole timeline's events from the events directory.
(ns strategies
  (:require [babashka.nrepl.server :as nrepl]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import (java.net ServerSocket)))

(def ms 1000000)

;; What the strategies saw ------------------------------------------------------------------------

(defonce generations (atom [])) ; [{:generation :candidates :chosen :strategy}]
(defonce ends (atom {}))        ; branch index -> {:outcome :events :failing}
(defonce starts (atom {}))      ; branch index -> {:seed :from}
(defonce events-dir (atom nil))

(defn timeline
  "A timeline's events (its own part: a tree branch begins inside its ancestors)."
  [index]
  (let [file (io/file @events-dir (str "branch-" index ".jsonl"))]
    (with-open [reader (io/reader file)]
      (doall (map #(json/parse-string % true) (line-seq reader))))))

(defn failing [] (into {} (filter (comp seq :failing val)) @ends))

;; Strategies -------------------------------------------------------------------------------------

(defn- room-end [{:keys [start_ns end_ns]}] (+ start_ns (quot (* 4 (- end_ns start_ns)) 5)))

(defn- clamp-moment [{:keys [start_ns end_ns]} at]
  (-> at (max (+ start_ns ms)) (min (- end_ns ms))))

(defn- new-behaviors [candidate] (filter #(pos? (:new_in_generation %)) (:behaviors candidate)))

(defn rarity
  "The explorer's own rule (Go-Explore's frontier): timelines scored by their new behaviors, each
  weighing 1 / the timelines of its generation that reached it; return just after the rarest one
  that leaves room to go on."
  [generation candidates count]
  (->> candidates
       (keep (fn [c]
               (let [fresh (new-behaviors c)
                     roomy (filter #(<= (:vtime_ns %) (room-end c)) fresh)]
                 (when (seq roomy)
                   (let [best (apply min-key :new_in_generation roomy)] ; The latest among equals.
                     {:score (reduce + (map #(/ 1.0 (:new_in_generation %)) fresh))
                      :branch (:branch c)
                      :vtime_ns (clamp-moment c (+ (:vtime_ns best) 1000))
                      :reason (str "rarity: just after " (:label best) ", reached first by "
                                   (:new_in_generation best) " timelines of generation "
                                   generation)})))))
       (sort-by (comp - :score))
       (take count)))

(defn rarest-ever
  "Behaviors rare across the whole exploration (fewest timelines before), not just new to the
  generation: return just after the rarest behavior any candidate reached."
  [_generation candidates count]
  (->> candidates
       (mapcat (fn [c] (for [b (:behaviors c) :when (<= (:vtime_ns b) (room-end c))] [c b])))
       (sort-by (fn [[_ b]] [(:timelines_before b) (- (:vtime_ns b))]))
       (map (fn [[c b]] {:branch (:branch c)
                         :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000))
                         :reason (str "rarest-ever: " (:label b) ", reached by "
                                      (:timelines_before b) " timelines before")}))
       (reduce (fn [chosen r] (if (some #(= (:branch %) (:branch r)) chosen) chosen (conj chosen r)))
               [])
       (take count)))

(defn uniform
  "A baseline: random timelines, random moments."
  [_generation candidates count]
  (for [c (take count (shuffle (filter #(> (- (:end_ns %) (:start_ns %)) (* 2 ms)) candidates)))]
    {:branch (:branch c)
     :vtime_ns (+ (:start_ns c) ms (rand-int (max 1 (- (:end_ns c) (:start_ns c) (* 2 ms)))))
     :reason "uniform: a random moment of a random timeline"}))

(defn deepest
  "Depth first: the latest new behavior of each timeline, the timelines with the latest first."
  [generation candidates count]
  (->> candidates
       (keep (fn [c] (when-let [b (last (sort-by :vtime_ns (new-behaviors c)))]
                       {:branch (:branch c)
                        :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000))
                        :reason (str "deepest: after " (:label b) " (generation " generation ")")})))
       (sort-by (comp - :vtime_ns))
       (take count)))

(defonce strategies
  (atom {:explorer {:returns (fn [& _] nil)} ; The explorer's built-in choice (a baseline).
         :rarity {:returns #'rarity}
         :rarest-ever {:returns #'rarest-ever}
         :uniform {:returns #'uniform}
         :deepest {:returns #'deepest}}))

(defonce current (atom :rarity))

(defn use-strategy! [name]
  (assert (contains? @strategies name) (str "no strategy " name))
  (reset! current name))

;; The protocol -----------------------------------------------------------------------------------

(defn answer [{:keys [method] :as request}]
  (case method
    "hello" {:name (str "clojure/" (name @current)) :decides false :wants ["behaviors"]}
    "branch" (do (swap! starts assoc (:index request) (select-keys request [:seed :from])) {})
    "branch_end" (do (swap! ends assoc (:index request) (select-keys request [:outcome :events :failing])) {})
    "returns" (let [{:keys [generation candidates count]} request
                    strategy @current
                    chosen (try (vec ((:returns (get @strategies strategy)) generation candidates count))
                                (catch Exception e
                                  (binding [*out* *err*] (println "strategy" strategy "failed:" (ex-message e)))
                                  []))]
                (swap! generations conj {:generation generation :strategy strategy
                                         :candidates candidates :chosen chosen})
                (if (seq chosen)
                  {:returns (mapv #(select-keys % [:branch :vtime_ns :reason]) chosen)}
                  {}))
    {}))

(defn- serve-connection [socket]
  (future
    (with-open [socket socket
                reader (io/reader (.getInputStream socket))
                writer (io/writer (.getOutputStream socket))]
      (doseq [line (line-seq reader)]
        (.write writer (str (json/generate-string (answer (json/parse-string line true))) "\n"))
        (.flush writer)))))

(defn- serve-control [socket]
  (future
    (with-open [socket socket
                reader (io/reader (.getInputStream socket))
                writer (io/writer (.getOutputStream socket))]
      (doseq [line (line-seq reader)]
        (let [[command argument] (str/split (str/trim line) #"\s+" 2)
              reply (case command
                      "use" (try (use-strategy! (keyword argument)) "ok"
                                 (catch Throwable e (str "error " (ex-message e))))
                      "reset" (do (reset! generations []) (reset! ends {}) (reset! starts {}) "ok")
                      "events-dir" (do (reset! events-dir argument) "ok")
                      (str "error unknown command " command))]
          (.write writer (str reply "\n"))
          (.flush writer))))))

(defn- listen [port serve]
  (let [server (ServerSocket. port 50 (java.net.InetAddress/getByName "127.0.0.1"))]
    (future (loop [] (serve (.accept server)) (recur)))
    server))

(defn -main [& args]
  (let [options (apply hash-map args)
        port (parse-long (get options "--port" "9100"))
        control (parse-long (get options "--control" "9101"))
        repl (parse-long (get options "--nrepl" "1667"))]
    (when-let [strategy (get options "--strategy")] (use-strategy! (keyword strategy)))
    (reset! events-dir (get options "--events-dir"))
    (listen port serve-connection)
    (listen control serve-control)
    (nrepl/start-server! {:host "127.0.0.1" :port repl})
    (println (str "strategies: protocol on 127.0.0.1:" port ", control on " control ", nREPL on "
                  repl "; strategy " (name @current)))
    @(promise)))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
