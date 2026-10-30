;; SPDX-License-Identifier: MIT
;; A run's notebook, evaluated by babashka (serve.zig runs it: bb notebook.clj <input.json>).
;; Cells are Clojure, evaluated in order in one namespace (as Antithesis's notebook): what a cell
;; defines, later cells use. Each cell shows what it printed and its value: events as a log, data
;; as EDN, markdown with `md`. Queries, event sets and SQL ask the run's events database through
;; serve; actions (replay, stacks, profile, extract) run when clicked in the UI, and their
;; results come back here for later cells.
;;
;; Over nREPL (serve.zig starts `bb --init notebook.clj nrepl-server` for a run), the same
;; names are in `user`, and actions run at once, through serve's HTTP API.
;;
;; Input:  {"cells": ["(code)", ...], "results": {"<action label>": result}}
;; Output: {"cells": [{"outputs": [{"type": "text"|"md"|"edn"|"events"|"action"|"error", ...}]}]}
(ns determinismo.notebook
  (:require [cheshire.core :as json]
            [clojure.pprint :as pprint]
            [clojure.string :as str]
            [babashka.http-client :as http]
            [babashka.process :as process]))

(def ^:private environment
  {:determinismo (or (System/getenv "DETERMINISMO") "determinismo")
   :record (System/getenv "DETERMINISMO_RECORD")
   ;; Serve, which holds the run's events database: queries, event sets and SQL go through it.
   :serve (System/getenv "DETERMINISMO_SERVE")
   ;; Set over nREPL: actions run at once, through serve's API for this run.
   :api (System/getenv "DETERMINISMO_API")
   :run (System/getenv "DETERMINISMO_RUN")})

(def ^:dynamic *outputs* nil)
(def ^:private results (atom {}))

(defn- show! [output] (swap! *outputs* conj output))

(defn- json-lines [text]
  (->> (str/split-lines text) (remove str/blank?) (mapv #(json/parse-string % true))))

(defn- database
  "Asks the run's events database (through serve): the answer's text."
  [path request]
  (let [url (str (:serve environment) "/runs/" (:run environment) "/" path)
        response (http/post url {:body (json/generate-string request) :throw false
                                 :headers {"Content-Type" "application/json"} :timeout 600000})]
    (when-not (= 200 (:status response))
      (throw (ex-info (str path ": " (:body response)) {:request request})))
    (:body response)))

;; Built-ins -------------------------------------------------------------------------------

(def run
  "The run's record: what was explored ({:scenario :program :seed ...}), its timelines and summary."
  (let [lines (some-> (:record environment) slurp json-lines)]
    {:run (some :run lines)
     :snapshot (some :snapshot lines)
     :summary (some :summary lines)
     :branches (vec (keep :branch lines))}))

(defn query
  "Events of every timeline matching a condition (query.zig's language):
  (query \"assert.condition=false\" {:limit 20 :preceded_by \"event=fault\" :within 1})."
  ([condition] (query condition {}))
  ([condition options] (json-lines (database "query" (merge {:condition condition :limit 100} options)))))

(defn events
  "An event set pipeline (event_sets.zig): (events [{:filter \"assert.condition=false\"}
  {:with_last {:fault \"event=fault\"}}] {:limit 50})."
  ([pipeline] (events pipeline {}))
  ([pipeline options] (json-lines (database "events" (merge {:pipeline pipeline :limit 100} options)))))

(def sources
  "The run's events by source, as Antithesis's environment names them (conditions for query):
  (query (:faults sources) {:limit 20})."
  {:containers "output.source?"
   :assertions "assert.message?"
   :sdk "assert.message? or event? or decision?"
   :fault-injector "event=faults_start or event=faults_stop or event=faults_phase or event=fault_failed"
   :faults "event=fault"
   :nodes "event=node_start or event=node_ready or event=node_kill or event=node_crash"
   ;; The kernel's log is read when a timeline ends: its OOM kills, crashes and warnings.
   :journal "assert.message~kernel or assert.message~\"no process crashes\""})

(defn why
  "Why a timeline went as it did, in order: the tree's reason for starting it where it did, each
  fault and why it was that one (drawn, aimed at the node the scenario names, after a branch
  point at its node, or asked for by the scenario), and each decision a strategy explained.
  (why 12), (why 12 {:limit 1000})."
  ([branch] (why branch {}))
  ([branch options]
   (let [started (some #(when (= branch (:index %)) (:why %)) (:branches run))
         happened (query "event=fault or event=decision" (merge {:branch branch :limit 500} options))]
     (into (if (str/blank? started) [] [{:at 0 :what "the timeline" :why started}])
           (keep (fn [{:keys [vtime_ns event]}]
                   (let [details (:details event)
                         at (/ (or vtime_ns 0) 1e9)]
                     (if (= "fault" (:event event))
                       {:at at
                        :what (str/join " " (remove str/blank? [(:kind details) (:node details) (:peer details)]))
                        :why (cond (:injected details) "asked for by the scenario"
                                   (= "aimed" (:why details)) "aimed at the node the scenario names"
                                   (= "branch_point" (:why details)) "after a branch point at its node"
                                   :else "drawn")}
                       (when (:reason details) {:at at :what "decision" :why (:reason details)})))))
           happened))))

(defn sql
  "One SELECT on the run's events database (tables events, timelines, steps; the view
  timeline_events): its rows. (sql \"SELECT kind, count(*) AS n FROM events GROUP BY kind\")."
  [text]
  (json/parse-string (database "sql" {:sql text}) true))

(defn md
  "Shows markdown."
  [& parts]
  (show! {:type "md" :text (apply str parts)})
  ::shown)

(defn- printed
  "What a replay's command printed, from its output (determinismo's lines after it)."
  [text]
  (let [lines (str/split-lines text)
        output (keep #(when-let [at (str/index-of % "{\"event\":\"exec_output\"")]
                        (-> (subs % at) (json/parse-string true) :details :text))
                     lines)]
    (str (str/join output) "\n" (str/join "\n" (filter #(str/starts-with? % "[branch") lines)))))

(defn- perform [{:keys [path body download raw]}]
  (let [url (str (:api environment) "/runs/" (:run environment) "/" path)
        response (http/post url {:body (json/generate-string body) :throw false
                                 :headers {"Content-Type" "application/json"}
                                 :as (if download :bytes :string) :timeout 3600000})]
    (when-not (= 200 (:status response))
      (throw (ex-info (str path ": " (:body response)) {:status (:status response)})))
    (if download
      (let [file (str "/tmp/determinismo-run-" (:run environment) "-" (last (str/split (:path body) #"/")))]
        (with-open [stream (java.io.FileOutputStream. file)] (.write stream ^bytes (:body response)))
        {:file file :bytes (count (:body response))})
      (if raw (:body response) (printed (:body response))))))

(defn- action [label request]
  (if (:api environment)
    (perform request)
    (let [done (get @results label)]
      (show! {:type "action" :label label :request request :result done})
      {:action label :result done})))

(defn- moment [options]
  (select-keys options [:branch :at_vtime_ms :until :rewind_ms]))

(defn- fresh-seed
  "A branch's own randomness from its moment on, as Antithesis's branches diverge from their
  timeline: a seed from the branch's moment and steps (the same branch replays the same), or
  the one given (:seed); :same-future keeps the timeline's randomness."
  [options moment steps]
  (when-not (:same-future options)
    (or (:seed options) (Math/abs (long (hash [moment steps]))))))

(def ^:private profiler "/opt/determinismo/bin/det-profile")

(defn replay
  "Replays a timeline to a moment and runs a command there (when clicked):
  (replay {:branch 0 :at_vtime_ms 1550 :exec \"det-nodes exec redis redis-cli get balance:0\"})."
  [options]
  (let [body (cond-> (moment options) (:exec options) (assoc :exec (:exec options)))]
    (action (str "replay " (json/generate-string body)) {:path "replay" :body body})))

(defn stacks
  "Every thread's stack in a node at a moment: (stacks {:branch 0 :at_vtime_ms 1550 :node \"redis\"})."
  [options]
  (replay (assoc options :exec (str profiler " " (:node options) " --stacks"))))

(defn profile
  "Where a node spends its CPU from a moment: (profile {:branch 0 :at_vtime_ms 1550 :node \"redis\" :ms 500})."
  [options]
  (replay (assoc options :exec (str profiler " " (:node options) " --ms " (or (:ms options) 1000) " --all"))))

(defn extract
  "A node's file at a moment, to download: (extract {:branch 0 :at_vtime_ms 1550 :node \"redis\" :path \"/data/dump.rdb\"})."
  [options]
  (let [body (merge (moment options) (select-keys options [:node :path]))]
    (action (str "extract " (json/generate-string body)) {:path "extract" :body body :download true})))

(defn branch
  "A branch from a moment of a timeline (Antithesis's moment.branch()), grown with bash,
  bash-bg, wait and wait-until, then replayed by run-branch. Its future is its own (new
  randomness from the moment, the same each time it runs; :seed n for another, :same-future true
  for the timeline's):
  (-> (branch {:branch 0 :at_vtime_ms 1550})
      (bash \"redis-cli get balance:0\" {:node \"redis\"})
      (bash-bg \"redis-cli monitor\" {:node \"redis\"})
      (wait 500)
      (wait-until \"output.source=redis\" {:timeout_ms 2000})
      run-branch)"
  [options]
  {:moment (moment options) :steps [] :options (select-keys options [:seed :same-future])})

(defn bash
  "A command run to its end (in :node, else in the runner): the branch goes on once it exits."
  [branch command & [{:keys [node]}]]
  (update branch :steps conj (cond-> {:exec command} node (assoc :node node))))

(defn bash-bg
  "A command run in the background (run_in_background): the branch goes on once it started."
  [branch command & [{:keys [node]}]]
  (update branch :steps conj (cond-> {:exec command :background true} node (assoc :node node))))

(defn wait
  "The branch runs on for ms of virtual time (branch.wait)."
  [branch ms]
  (update branch :steps conj {:wait_ms ms}))

(defn wait-until
  "The branch runs on until an event matches a condition, or timeout_ms passed (wait_until)."
  [branch condition & [{:keys [timeout_ms]}]]
  (update branch :steps conj (cond-> {:until condition} timeout_ms (assoc :timeout_ms timeout_ms))))

(defn faults-pause
  "The fault injector stops from here (faults under way undone), as Antithesis's
  environment.fault_injector.pause: a step of the branch."
  [branch]
  (update branch :steps conj {:exec "/opt/determinismo/bin/det-stop-faults 86400"}))

(defn faults-resume
  "The fault injector goes on (environment.fault_injector.unpause): a step of the branch."
  [branch]
  (update branch :steps conj {:exec "/opt/determinismo/bin/det-stop-faults 0"}))

(defn- branch-result
  "A branch's replay as data: the moment each step ended at (:moments, the first the branch's
  start), whether each wait-until's condition held (:timed-out, by step), and every command as a
  process: its :id, :command, :background, :output, :exit-code, :started-ns, :ended-ns (nil
  while it runs: (exited-by? process moment) as Antithesis's exited_by)."
  [text]
  (let [lines (str/split-lines text)
        moments (vec (keep #(when-let [[_ vtime branches] (re-find #"\[determinismo\] at moment vtime=(\d+)ns branches=(\d+)" %)]
                              {:vtime_ns (parse-long vtime) :branches (parse-long branches)})
                           lines))
        events (keep #(when-let [[_ at json] (re-find #"^\[guest @ (\d+)ns\] (\{\"event\":\"exec_.*)$" %)]
                        (assoc (json/parse-string json true) :vtime_ns (parse-long at)))
                     lines)
        processes (reduce (fn [found {:keys [event details vtime_ns]}]
                            (let [id (:id details)]
                              (case event
                                "exec_start" (assoc found id {:id id :command (:command details)
                                                              :background (boolean (:background details))
                                                              :started-ns vtime_ns :output ""})
                                "exec_output" (update-in found [id :output] str (:text details))
                                "exec_done" (update found id assoc :exit-code (:status details) :ended-ns vtime_ns)
                                found)))
                          (sorted-map) events)]
    {:moments moments
     :end (peek moments)
     :timed-out (count (filter #(str/includes? % "until: timed out") lines))
     ;; Not the platform's own steps (": det:reseed", run by a guest older than it).
     :processes (vec (remove #(some-> (:command %) (str/starts-with? ": det:")) (vals processes)))
     :replay (str/join "\n" (filter #(str/starts-with? % "[branch") lines))}))

(defn exited-by?
  "Whether a branch's process had exited at a moment (one of its :moments)."
  [process moment]
  (boolean (and (:ended-ns process) (<= (:ended-ns process) (:vtime_ns moment)))))

(defn run-branch
  "Replays a branch (when clicked; at once over nREPL): its moments and processes (branch-result)."
  [branch]
  (let [seed (fresh-seed (:options branch) (:moment branch) (:steps branch))
        body (cond-> (assoc (:moment branch) :steps (:steps branch)) seed (assoc :fresh_seed seed))
        done (action (str "branch " (json/generate-string body)) {:path "replay" :body body :raw true})]
    (cond (string? done) (branch-result done)
          (string? (:result done)) (assoc done :result (branch-result (:result done)))
          :else done)))

(defn containers
  "The nodes (containers) as of a moment, as Antithesis's environment.containers.list: name,
  state, pid, address and image: (containers {:branch 0 :at_vtime_ms 1550})."
  [options]
  (let [body (assoc (moment options) :exec "det-nodes list")
        ;; Its lines, printed as they are or in exec_output events.
        parse (fn [text]
                (let [printed (str/join (keep #(when-let [at (str/index-of % "{\"event\":\"exec_output\"")]
                                                 (-> (subs % at) (json/parse-string true) :details :text))
                                              (str/split-lines text)))]
                  (->> (concat (str/split-lines printed) (str/split-lines text))
                       (keep #(when (str/starts-with? (str/trim %) "{\"name\"")
                                (try (json/parse-string (str/trim %) true) (catch Exception _ nil))))
                       distinct vec)))
        done (action (str "containers " (json/generate-string body)) {:path "replay" :body body :raw true})]
    (cond (string? done) (parse done)
          (string? (:result done)) (assoc done :result (parse (:result done)))
          :else done)))

(defn result
  "What a clicked action returned (nil before it ran)."
  [action-or-label]
  (get @results (if (map? action-or-label) (:action action-or-label) action-or-label)))

;; Evaluation ------------------------------------------------------------------------------

(defn- events? [value]
  (and (sequential? value) (seq value) (every? #(and (map? %) (contains? % :event) (contains? % :vtime_ns)) value)))

(defn- value-output [value]
  (cond
    (or (nil? value) (= value ::shown) (and (map? value) (contains? value :action))) nil
    (events? value) {:type "events" :events (vec (take 2000 value)) :count (count value)}
    (string? value) {:type "text" :text value}
    :else {:type "edn" :text (str/trimr (with-out-str (pprint/pprint value)))}))

(defn- evaluate-cell [code]
  (binding [*outputs* (atom [])]
    (try
      (let [printed (java.io.StringWriter.)
            value (binding [*out* printed] (load-string code))]
        (when (pos? (.length (str printed))) (swap! *outputs* #(into [{:type "text" :text (str printed)}] %)))
        (when-let [output (value-output value)] (show! output))
        {:outputs @*outputs*})
      (catch Throwable error
        {:outputs (conj @*outputs* {:type "error" :text (or (ex-message error) (str error))})
         :failed true}))))

(def ^:private names '[run query events sql md replay stacks profile extract result
                        branch bash bash-bg wait wait-until run-branch exited-by?
                        containers faults-pause faults-resume sources])

(defn -main [input-path]
  (let [input (json/parse-string (slurp input-path))]
    (reset! results (get input "results" {}))
    (create-ns 'notebook)
    (binding [*ns* (the-ns 'notebook)]
      (refer-clojure)
      (refer 'determinismo.notebook :only names)
      (require '[clojure.string :as str])
      (let [outputs (loop [[code & more] (get input "cells") done []]
                      (if (nil? code)
                        done
                        (let [cell (evaluate-cell code)]
                          ;; Later cells may need what a failed one did not define.
                          (if (:failed cell)
                            (into (conj done cell) (map (fn [_] {:outputs []}) more))
                            (recur more (conj done cell))))))]
        (println (json/generate-string {:cells (mapv #(dissoc % :failed) outputs)}))))))

(if (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*)
  ;; Loaded first by an nREPL server: the notebook's names, where a session starts.
  (binding [*ns* (create-ns 'user)]
    (refer 'determinismo.notebook :only names)))
