;; SPDX-License-Identifier: MIT
;; determinismo's HTTP API (src/serve.zig) from Clojure: runs, their timelines and properties,
;; events (query, event sets, SQL), replays, causality analyses, starting and stopping runs,
;; uploading strategies and planners. Load it in any REPL (`(load-file "plugins/clojure/api.clj")`,
;; babashka or the JVM with babashka.http-client and cheshire), or from a program:
;;
;;   (binding [api/*url* "http://100.116.225.66:7878"] (api/runs))
;;   (api/properties 93)
;;   (api/query 93 {:condition "event=fault" :branch 4862 :up_to_vtime 24.5})
;;   (api/causality-start 93 {:branch 4862 :property "[log-matching] ..." :planner "tcp://127.0.0.1:9102"})
;;
;; `*url*` is serve's address: $DETERMINISMO_URL, else http://127.0.0.1:7878.
(ns determinismo.api
  (:require [babashka.http-client :as http]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str]))

(def ^:dynamic *url* (or (System/getenv "DETERMINISMO_URL") "http://127.0.0.1:7878"))

(defn- check [response]
  (when (>= (:status response) 400)
    (throw (ex-info (str "determinismo: " (:status response) " " (:body response))
                    {:status (:status response) :body (:body response)})))
  (:body response))

(defn- parse
  "A JSON document, or JSON lines (queries and event sets answer one value per line)."
  [body]
  (let [lines (remove str/blank? (str/split-lines (or body "")))]
    (if (= 1 (count lines))
      (json/parse-string (first lines) true)
      (mapv #(json/parse-string % true) lines))))

(defn- lines [body]
  (mapv #(json/parse-string % true) (remove str/blank? (str/split-lines (or body "")))))

(defn request
  "Any endpoint: `method` (:get, :post, :put), a path under *url* or a whole URL, a body
  (a map is sent as JSON). The raw answer (a string)."
  [method path & [body]]
  (let [url (if (str/starts-with? path "http") path (str *url* path))]
    (check (http/request {:method method
                          :uri url
                          :headers {"Content-Type" "application/json"}
                          :body (cond (nil? body) nil
                                      (string? body) body
                                      (map? body) (json/generate-string body)
                                      :else body)
                          :throw false}))))

;; Runs ------------------------------------------------------------------------------------------

(defn runs [] (parse (request :get "/runs")))
(defn run [id] (parse (request :get (str "/runs/" id))))
(defn start-run
  "Starts a run: {:program | :compose, :scenario, :seed, :branches, :jobs, :time_budget,
  :strategy, :faults, ...} (serve's RunRequest). Its id."
  [request-map]
  (parse (request :post "/runs" request-map)))
(defn stop-run [id] (parse (request :post (str "/runs/" id "/stop"))))
(defn output [id] (request :get (str "/runs/" id "/output")))

;; What a run found ------------------------------------------------------------------------------

(defn timelines
  "Every finished timeline (index, seed, outcome, vtime_ns, failing, path, why, ...), or those
  after the first `offset` ingested."
  ([id] (parse (request :get (str "/runs/" id "/timelines"))))
  ([id offset] (parse (request :get (str "/runs/" id "/timelines?offset=" offset)))))
(defn properties [id] (parse (request :get (str "/runs/" id "/properties"))))
(defn discovery [id] (parse (request :get (str "/runs/" id "/discovery"))))
(defn findings [id] (parse (request :get (str "/runs/" id "/findings"))))

;; Events ----------------------------------------------------------------------------------------

(defn query
  "Events matching a condition (query.zig): {:condition, :branch, :up_to_vtime (s), :output
  (events | count | branches | marks), :timelines, :limit, ...}. A vector, one per event."
  [id request-map]
  (lines (request :post (str "/runs/" id "/query") request-map)))

(defn query-at
  "`query` at a run's whole URL (as causality planners are told it: http://host:port/runs/<id>)."
  [run-url request-map]
  (lines (request :post (str run-url "/query") request-map)))

(defn events [id request-map] (lines (request :post (str "/runs/" id "/events") request-map)))
(defn sql [id text] (parse (request :post (str "/runs/" id "/sql") {:sql text})))

(defn faults
  "The faults a timeline went through up to `up-to-ms` (its ancestors' included), as
  {:vtime_ms :kind :node :peer :details}."
  ([id branch up-to-ms] (faults (str *url* "/runs/" id) branch up-to-ms nil))
  ([run-url branch up-to-ms _]
   (for [event (query-at run-url {:condition "event=fault" :branch branch
                                  :up_to_vtime (/ (+ up-to-ms 1) 1000.0) :limit 100000})
         :let [details (get-in event [:event :details])]]
     {:vtime_ms (quot (:vtime_ns event) 1000000)
      :kind (:kind details) :node (:node details) :peer (:peer details) :details details})))

;; Replays and analyses --------------------------------------------------------------------------

(defn replay
  "Replays one timeline: {:branch, :at_vtime_ms | :until (:rewind_ms), :exec}. Its output."
  [id request-map]
  (request :post (str "/runs/" id "/replay") request-map))

(defn causality-start
  "Starts a causality analysis: {:branch :property :points :futures :refine :moments_max
  :jump_min :gap_min_ms :planner}. Its {:id}."
  [id request-map]
  (parse (request :post (str "/runs/" id "/causality") request-map)))

(defn causality
  "Every analysis of a run, or one: {:id :done :of {...} :points [...]}."
  ([id] (parse (request :get (str "/runs/" id "/causality"))))
  ([id n] (parse (request :get (str "/runs/" id "/causality/" n)))))

(defn causality-wait
  "Waits for an analysis to finish (polling every `every-ms`), and returns it."
  [id n & {:keys [every-ms] :or {every-ms 3000}}]
  (loop []
    (let [analysis (causality id n)]
      (if (:done analysis) analysis (do (Thread/sleep every-ms) (recur))))))

;; Plugins on the server -------------------------------------------------------------------------

(defn strategies [] (parse (request :get "/strategies")))
(defn upload-strategy
  "Uploads an executable as a strategy (or causality planner) named `name`: runs and analyses
  then name it `@name`."
  [name file]
  (parse (request :put (str "/strategies/" name) (io/file file))))
