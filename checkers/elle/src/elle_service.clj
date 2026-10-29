;; SPDX-License-Identifier: MIT
;; Elle as a service: POST a history (JSON lines, one operation each, in the order they happened)
;; to /check?model=list-append&consistency=strict-serializable, get Elle's verdict as JSON.
;;
;; An operation: {"process": 7, "type": "invoke", "f": "txn",
;;                "value": [["append", 3, 17], ["r", 4, null]]}
;; then its completion by the same process: "ok" (reads filled in), "fail" (it did not happen)
;; or "info" (unknown). Models: list-append ([append k v], [r k [v ...]]) and rw-register
;; ([w k v], [r k v]). An invocation never completed (its driver stopped mid-call) is closed as
;; info. The answer: {"valid": true | false | "unknown", "anomaly_types": [...], "not": [...],
;; "ops": n, "anomalies": "..."} (the anomalies as Elle prints them, cut short).
(ns elle-service
  (:gen-class)
  (:require [clojure.data.json :as json]
            [clojure.string :as string]
            [clojure.walk :as walk]
            [elle.list-append :as list-append]
            [elle.rw-register :as rw-register]
            [jepsen.history :as history])
  (:import (com.sun.net.httpserver HttpExchange HttpHandler HttpServer)
           (java.net InetSocketAddress URLDecoder)
           (java.nio.charset StandardCharsets)
           (java.util.concurrent Executors)))

;; ELLE_PORT: another beside the host's (a test of the service itself).
(def port (Integer/parseInt (or (System/getenv "ELLE_PORT") "7700")))
;; What `/version` answers: the SDK (sdk/zig/elle.zig) replaces a running service that answers
;; another. 2: operations' times, and the window the anomalies formed in (window_ns). 3: reads
;; with a value twice reported here (duplicates).
(def version "3")
(def anomalies-size-max 4000)
;; Histories checked at once (a run's timelines end together), on as many threads: without an
;; executor the server ran every handler on its one thread, so a long check kept `/version` from
;; answering and the SDK replaced the service mid-check (run 200's timeline 151, srv3 2026-10-29).
(def threads 4)

(defn- operation [m]
  {:process (get m "process")
   :type (keyword (get m "type"))
   :f (keyword (get m "f"))
   :time (get m "time" -1)
   :value (mapv (fn [[f k v]] [(keyword f) k v]) (get m "value"))})

(defn- window
  "When the anomalies formed: the earliest and the latest time (the guest's clock, in
  nanoseconds) of the operations they name, or nil when they name none with a time."
  [anomalies]
  (let [times (->> (tree-seq coll? seq anomalies)
                   (keep #(when (map? %) (:time %)))
                   (filter #(and (number? %) (>= % 0))))]
    (when (seq times) [(apply min times) (apply max times)])))

(defn- closed
  "The operations, with every invocation left open closed as :info (by process, in order)."
  [operations]
  (let [open (reduce (fn [open o]
                       (if (= :invoke (:type o))
                         (assoc open (:process o) o)
                         (dissoc open (:process o))))
                     (sorted-map) operations)]
    (into (vec operations) (map #(assoc % :type :info)) (vals open))))

(defn- shortened
  "Long lists of values (a read's) cut to their ends and a count: Elle prints an anomaly's reader
  first, and a read of hundreds of values left no room for the writer and the element."
  [x]
  (walk/postwalk (fn [v]
                   (if (and (vector? v) (> (count v) 8) (every? number? v))
                     (vec (concat (take 3 v)
                                  [(symbol (str "..." (- (count v) 6) "-more..."))]
                                  (take-last 3 v)))
                     v))
                 x))

(defn- duplicates
  "The list reads that hold a value twice. Appends are unique, so each is an anomaly; Elle crashed
  on them (a ClassCastException, OpenSearch run 176's timeline 27: a write answered with a
  conflict had taken effect, and its client appended again), so they are found here and Elle
  judges the reads with each value once."
  [operations]
  (vec (for [o operations
             :when (= :ok (:type o))
             [f k v] (:value o)
             :when (and (= :r f) (sequential? v) (not= (count v) (count (distinct v))))]
         {:op o :key k :values (vec (keep (fn [[x n]] (when (< 1 n) x)) (frequencies v)))})))

(defn- deduplicated [operations]
  (map (fn [o]
         (update o :value
                 (fn [mops]
                   (mapv (fn [[f k v :as mop]]
                           (if (and (= :r f) (sequential? v)) [f k (vec (distinct v))] mop))
                         mops))))
       operations))

(defn check [body model consistency]
  (let [operations (->> (string/split-lines body)
                        (remove string/blank?)
                        (map json/read-str)
                        (map operation)
                        closed)
        twice (when (= model "list-append") (duplicates operations))
        checker (case model
                  "list-append" list-append/check
                  "rw-register" rw-register/check)
        result (checker {:consistency-models [(keyword consistency)]}
                        (history/history (if (seq twice) (deduplicated operations) operations)))
        result (if (seq twice)
                 (-> result
                     (assoc :valid? false)
                     (update :anomaly-types #(distinct (conj (vec %) :duplicate-elements)))
                     (assoc-in [:anomalies :duplicate-elements] twice))
                 result)
        valid (:valid? result)
        formed (window (:anomalies result))
        anomalies (pr-str (shortened (:anomalies result)))]
    {:valid (if (keyword? valid) (name valid) valid)
     :anomaly_types (map name (:anomaly-types result))
     :not (map name (:not result))
     :ops (count operations)
     :window_ns formed
     :anomalies (subs anomalies 0 (min anomalies-size-max (count anomalies)))}))

(defn- parameters [^HttpExchange exchange]
  (into {}
        (for [pair (string/split (or (.getRawQuery (.getRequestURI exchange)) "") #"&")
              :let [[k v] (string/split pair #"=" 2)]
              :when (seq k)]
          [k (URLDecoder/decode (or v "") StandardCharsets/UTF_8)])))

(defn- respond [^HttpExchange exchange status value]
  (let [bytes (.getBytes ^String (json/write-str value) StandardCharsets/UTF_8)]
    (.add (.getResponseHeaders exchange) "Content-Type" "application/json")
    (.sendResponseHeaders exchange status (alength bytes))
    (with-open [out (.getResponseBody exchange)]
      (.write out bytes))))

(defn- handle [^HttpExchange exchange]
  (try
    (let [body (slurp (.getRequestBody exchange) :encoding "UTF-8")
          {:strs [model consistency]
           :or {model "list-append" consistency "strict-serializable"}} (parameters exchange)]
      (respond exchange 200 (check body model consistency)))
    (catch Throwable t
      (respond exchange 500 {:error (str t)}))
    (finally
      (.close exchange))))

(defn -main [& _]
  (let [server (HttpServer/create (InetSocketAddress. port) 16)]
    (.createContext server "/check" (reify HttpHandler (handle [_ exchange] (handle exchange))))
    (.createContext server "/version" (reify HttpHandler
                                        (handle [_ exchange]
                                          (try (respond exchange 200 {:version version})
                                               (finally (.close exchange))))))
    (.setExecutor server (Executors/newFixedThreadPool threads))
    (.start server)
    (println "elle-service on port" port)))
