#!/usr/bin/env bb
;; SPDX-License-Identifier: MIT
;; Exploration strategies in Clojure, served over TCP to `determinismo explore --strategy
;; tcp://127.0.0.1:<port>` (protocol v1, docs/PLUGINS.md), with an nREPL server: redefine a
;; strategy (or write a new one) from your editor, and the next generation uses it. No rebuild, no
;; restart.
;;
;;   bb plugins/clojure/strategies.clj [--port 9100] [--nrepl 1667] [--control 9101]
;;                                     [--strategy rarity] [--events-dir <explore's --events-dir>]
;;                                     [--planner-port 9102] [--planner faults]
;;
;; Causality planners too (`determinismo causality --planner tcp://127.0.0.1:9102`, or the
;; page's planner field): which moments of a failing timeline to analyze next, and how many
;; futures each (causality.zig's protocol). `(use-planner! :faults)` switches; `@plans` keeps
;; every round asked and answered. They reach the run over its HTTP API (api.clj, beside this).
;;
;; A strategy is a map in `strategies`: `:returns` gets the generation's candidates (each
;; timeline: its span and the behaviors it reached, with how many timelines reached them) and
;; chooses up to `count` moments to branch from, each {:branch :vtime_ns :reason}; nil or [] leaves
;; it to the explorer. `(use-strategy! :rarity)` switches; the control port takes "use <name>" (for
;; scripts: bench/explore.py). Everything seen is kept for the REPL: `@generations` (candidates and
;; choices), `@ends` (each timeline's outcome and failing properties), and `(timeline n)` reads a
;; whole timeline's events from the events directory.
(ns strategies
  (:require [babashka.fs :as fs]
            [babashka.nrepl.server :as nrepl]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import (java.net ServerSocket)))

(load-file (str (fs/parent *file*) "/api.clj"))
(alias 'api 'determinismo.api)

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

;; Go-Explore's archive, with the cell pluggable: every cell any timeline of any generation
;; reached, where (just after the first timeline reached it), how many timelines reached it and
;; how often it was returned to. `cell-of` makes a behavior a cell: redefine it from the REPL
;; (coarser: `(defn cell-of [b] (str/replace (:label b) #"\d+" "N"))`, or by what a domain
;; cares about) and the next generation uses it. `(reset! archive {})` starts over.
(defonce archive (atom {})) ; cell -> {:branch :vtime_ns :label :reached :returns}

(defn cell-of
  "A behavior's cell: its label (the explorer's own notion, each behavior a cell)."
  [behavior]
  (:label behavior))

(defn- archive-note! [candidates]
  (doseq [c candidates
          b (:behaviors c)
          :when (<= (:vtime_ns b) (room-end c))
          :let [cell (cell-of b)]
          :when cell]
    (swap! archive update cell
           (fn [known]
             (if known
               (update known :reached inc)
               {:branch (:branch c) :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000))
                :label (:label b) :reached 1 :returns 0})))))

(defn archived
  "Half the returns to the archive's least explored cells (score (1 + reached) * (1 + returns):
  rare, seldom returned to), from any generation; the rest to this generation's rarest new
  behaviors (rarity). All to the archive when nothing is new."
  [generation candidates count]
  (archive-note! candidates)
  (let [fresh (vec (rarity generation candidates count))
        wanted (if (seq fresh) (quot (inc count) 2) count)
        cells (->> @archive
                   (sort-by (fn [[_ {:keys [reached returns]}]] (* (inc reached) (inc returns))))
                   (take wanted))
        from-archive (for [[cell {:keys [branch vtime_ns label reached returns]}] cells]
                       (do (swap! archive update-in [cell :returns] inc)
                           {:branch branch :vtime_ns vtime_ns
                            :reason (str "archive: " label " (cell " cell "), reached by " reached
                                         " timelines, returned to " returns " times")}))]
    (vec (take count (concat (doall from-archive) fresh)))))

(defonce strategies
  (atom {:explorer {:returns (fn [& _] nil)} ; The explorer's built-in choice (a baseline).
         :rarity {:returns #'rarity}
         :rarest-ever {:returns #'rarest-ever}
         :uniform {:returns #'uniform}
         :deepest {:returns #'deepest}
         :archive {:returns #'archived}}))

(defonce current (atom :rarity))

(defn use-strategy! [name]
  (assert (contains? @strategies name) (str "no strategy " name))
  (reset! current name))

;; Causality planners -----------------------------------------------------------------------------
;; A plan request: {:round :branch :property :snapshot_ms :failure_ms :futures :points_asked
;; :jump_min :gap_min_ms :moments_left :run_url :tape :points [{:vtime_ms :futures :failing
;; :probability :low :high}]}. A plan: {:moments [{:vtime_ms :futures}] :note "why"}; none: done.

(defonce plans (atom [])) ; [{:planner :request :plan}]

(defn- evenly
  "Just after the setup snapshot (the bug's probability before the timeline did anything), then
  `count` moments evenly to the failure (the last one at it)."
  [{:keys [snapshot_ms failure_ms futures]} count]
  (cons {:vtime_ms (inc snapshot_ms) :futures futures}
        (for [index (range 1 (inc count))]
          {:vtime_ms (+ snapshot_ms (max 1 (quot (* (- failure_ms snapshot_ms) index) count)))
           :futures futures})))

(defn jumps
  "Neighboring points whose probabilities differ by jump_min or more and are gap_min_ms apart or
  more, the largest first: [[a b] ...]."
  [{:keys [points jump_min gap_min_ms]}]
  (->> (sort-by :vtime_ms points)
       (partition 2 1)
       (filter (fn [[a b]] (and (>= (- (:vtime_ms b) (:vtime_ms a)) gap_min_ms)
                                (>= (abs (- (:probability b) (:probability a))) jump_min))))
       (sort-by (fn [[a b]] (- (abs (- (:probability b) (:probability a))))))))

(defn plan-bisect
  "causality.zig's own: k moments evenly, then halfway inside the largest jumps."
  [{:keys [round points_asked futures] :as request}]
  (if (zero? round)
    {:moments (evenly request points_asked) :note "evenly"}
    {:moments (for [[a b] (take points_asked (jumps request))]
                {:vtime_ms (+ (:vtime_ms a) (quot (- (:vtime_ms b) (:vtime_ms a)) 2)) :futures futures})
     :note "halfway inside the jumps"}))

(defn plan-faults
  "Evenly first; then, inside each jump, a moment just before and just after every fault
  injected there (the timeline's, from the run's API): the probability on either side of a fault
  says whether that fault decided the bug. A jump with no fault in it is halved."
  [{:keys [round points_asked futures run_url branch failure_ms] :as request}]
  (if (or (zero? round) (nil? run_url))
    (plan-bisect request)
    (let [faults (api/faults run_url branch failure_ms nil)
          known (set (map :vtime_ms (:points request)))
          inside (fn [[a b]] (filter #(< (:vtime_ms a) (:vtime_ms %) (:vtime_ms b)) faults))
          around (fn [[a b] fault]
                   (for [t [(dec (:vtime_ms fault)) (inc (:vtime_ms fault))]
                         :when (and (< (:vtime_ms a) t) (<= t (:vtime_ms b)) (not (known t)))]
                     {:vtime_ms t :futures futures}))
          moments (for [jump (take points_asked (jumps request))
                        moment (let [in (inside jump)]
                                 (if (seq in)
                                   (mapcat #(around jump %) in)
                                   [{:vtime_ms (+ (:vtime_ms (first jump))
                                                  (quot (- (:vtime_ms (second jump)) (:vtime_ms (first jump))) 2))
                                     :futures futures}]))]
                    moment)]
      {:moments (distinct moments)
       :note (str "around the faults inside " (count (jumps request)) " jumps: "
                  (str/join ", " (for [jump (jumps request) fault (inside jump)]
                                   (str (:kind fault) " " (:node fault) " at " (:vtime_ms fault) "ms"))))})))

(defn plan-dense
  "Four times the moments, evenly, in one round: no refinement."
  [{:keys [round points_asked] :as request}]
  (if (zero? round)
    {:moments (evenly request (* 4 points_asked)) :note "dense"}
    {:moments []}))

(defonce planners
  (atom {:bisect {:plan #'plan-bisect}
         :faults {:plan #'plan-faults}
         :dense {:plan #'plan-dense}}))

(defonce current-planner (atom :faults))

(defn use-planner! [name]
  (assert (contains? @planners name) (str "no planner " name))
  (reset! current-planner name))

(defn plan-answer [{:keys [method] :as request}]
  (case method
    "hello" {:name (str "clojure/" (name @current-planner))}
    "plan" (let [planner @current-planner
                 plan (try ((:plan (get @planners planner)) request)
                           (catch Exception e
                             (binding [*out* *err*] (println "planner" planner "failed:" (ex-message e)))
                             {:moments [] :note (str "failed: " (ex-message e))}))
                 plan (update plan :moments vec)]
             (swap! plans conj {:planner planner :request request :plan plan})
             plan)
    {}))

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

(defn- serve-with [answer-fn]
  (fn [socket]
    (future
      (with-open [socket socket
                  reader (io/reader (.getInputStream socket))
                  writer (io/writer (.getOutputStream socket))]
        (doseq [line (line-seq reader)]
          (.write writer (str (json/generate-string (answer-fn (json/parse-string line true))) "\n"))
          (.flush writer))))))

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
                      "planner" (try (use-planner! (keyword argument)) "ok"
                                     (catch Throwable e (str "error " (ex-message e))))
                      "reset" (do (reset! generations []) (reset! ends {}) (reset! starts {})
                                  (reset! archive {}) "ok")
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
        planner-port (parse-long (get options "--planner-port" "9102"))
        repl (parse-long (get options "--nrepl" "1667"))]
    (when-let [strategy (get options "--strategy")] (use-strategy! (keyword strategy)))
    (when-let [planner (get options "--planner")] (use-planner! (keyword planner)))
    (reset! events-dir (get options "--events-dir"))
    (listen port (serve-with #'answer))
    (listen planner-port (serve-with #'plan-answer))
    (listen control serve-control)
    (nrepl/start-server! {:host "127.0.0.1" :port repl})
    (println (str "strategies: protocol on 127.0.0.1:" port ", causality planners on " planner-port
                  ", control on " control ", nREPL on " repl "; strategy " (name @current)
                  ", planner " (name @current-planner)))
    @(promise)))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
