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

(defn- perform [{:keys [path body download]}]
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
      (printed (:body response)))))

(defn- action [label request]
  (if (:api environment)
    (perform request)
    (let [done (get @results label)]
      (show! {:type "action" :label label :request request :result done})
      {:action label :result done})))

(defn- moment [options]
  (select-keys options [:branch :at_vtime_ms :until :rewind_ms]))

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

(def ^:private names '[run query events sql md replay stacks profile extract result])

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
