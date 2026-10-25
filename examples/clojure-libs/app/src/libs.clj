;; SPDX-License-Identifier: MIT
;; Clojure's most used libraries under determinismo: each endpoint runs one randomized check of
;; one library, its inputs drawn from platform randomness (steerable, replayed) and its verdict
;; asserted with the Clojure SDK (cataloged as this namespace loads). The test program
;; (libs_test.zig) calls them concurrently, under faults.
(ns libs
  (:require [clojure.core.async :as async]
            [clojure.data.json :as data-json]
            [cheshire.core :as cheshire]
            [clj-yaml.core :as yaml]
            [determinismo :as det]
            [jsonista.core :as jsonista]
            [malli.core :as malli]
            [malli.generator]
            [manifold.deferred :as deferred]
            [manifold.stream :as stream]
            [org.httpkit.server :as server]
            [taoensso.nippy :as nippy]))

;; Random data -------------------------------------------------------------------------------

(def ^:private alphabet "abcdefghijklmnopqrstuvwxyzÅäß→ \"\\\n\t{}[]:,0123456789-")

(defn- random-string []
  (apply str (repeatedly (det/random-below 24) #(nth alphabet (det/random-below (count alphabet))))))

(defn- random-scalar []
  (case (det/random-below 6)
    0 (- (det/random-below 2000000) 1000000)
    1 (random-string)
    2 (zero? (det/random-below 2))
    3 nil
    4 (/ (- (det/random-below 2000000) 1000000) 1000.0)
    5 (keyword (str "k" (det/random-below 100)))))

(defn- random-data
  "Nested maps and vectors of scalars, keys as strings (what JSON and YAML keep)."
  [depth]
  (if (or (zero? depth) (zero? (det/random-below 3)))
    (let [value (random-scalar)] (if (keyword? value) (name value) value))
    (if (zero? (det/random-below 2))
      (vec (repeatedly (det/random-below 5) #(random-data (dec depth))))
      (into {} (repeatedly (det/random-below 5) (fn [] [(random-string) (random-data (dec depth))]))))))

;; Round trips -------------------------------------------------------------------------------

(defn- same-json?
  "Equal as JSON sees data: numbers compared as doubles, keywords as strings."
  [a b]
  (cond (and (number? a) (number? b)) (== (double a) (double b))
        (and (map? a) (map? b)) (and (= (set (keys a)) (set (keys b)))
                                     (every? #(same-json? (get a %) (get b %)) (keys a)))
        (and (sequential? a) (sequential? b)) (and (= (count a) (count b))
                                                    (every? true? (map same-json? a b)))
        :else (= a b)))

(defn check-cheshire []
  (let [data (random-data 4)
        back (cheshire/parse-string (cheshire/generate-string data))]
    (det/always (same-json? data back) "cheshire: data round-trips through JSON"
                {:data (pr-str data) :back (pr-str back)})))

(defn check-jsonista []
  (let [data (random-data 4)
        back (jsonista/read-value (jsonista/write-value-as-string data))]
    (det/always (same-json? data back) "jsonista: data round-trips through JSON"
                {:data (pr-str data) :back (pr-str back)})))

(defn check-data-json []
  (let [data (random-data 4)
        back (data-json/read-str (data-json/write-str data))]
    (det/always (same-json? data back) "data.json: data round-trips through JSON"
                {:data (pr-str data) :back (pr-str back)})))

(defn check-yaml []
  (let [data (random-data 4)
        back (yaml/parse-string (yaml/generate-string data) :keywords false)]
    (det/always (same-json? data back) "clj-yaml: data round-trips through YAML"
                {:data (pr-str data) :back (pr-str back)})))

(defn check-nippy []
  ;; Nippy keeps Clojure types: keywords, ratios, sets.
  (let [data {:value (random-data 4) :set (set (repeatedly (det/random-below 4) random-string))
              :ratio (/ (inc (det/random-below 100)) (inc (det/random-below 100)))}
        back (nippy/thaw (nippy/freeze data))]
    (det/always (= data back) "nippy: data round-trips through freeze and thaw"
                {:data (pr-str data) :back (pr-str back)})))

(def ^:private schema
  [:map [:id :int] [:name :string] [:tags [:vector :keyword]] [:score [:maybe :double]]])

(defn check-malli []
  ;; Values malli generates from a schema are valid for it, and explain finds nothing in them.
  (let [value (malli.generator/generate schema {:seed (det/random-below 1000000) :size 8})]
    (det/always (malli/validate schema value) "malli: generated values are valid"
                {:value (pr-str value)})
    (det/always (nil? (malli/explain schema value)) "malli: explain finds nothing in valid values"
                {:value (pr-str value)})))

;; Concurrency -------------------------------------------------------------------------------

(defn check-core-async []
  ;; Producers put numbered messages on one buffered channel; a consumer takes them all. Every
  ;; message arrives exactly once, and each producer's in its order.
  (let [producers (inc (det/random-below 4))
        per (inc (det/random-below 50))
        size (det/random-below 8)
        channel (if (zero? size) (async/chan) (async/chan size)) ; 0: unbuffered
        done (async/chan)]
    (dotimes [p producers]
      (async/go (dotimes [i per] (async/>! channel [p i])) (async/>! done p)))
    (async/go (dotimes [_ producers] (async/<! done)) (async/close! channel))
    (let [received (async/<!! (async/into [] channel))
          by-producer (group-by first received)]
      (det/always (= (count received) (* producers per)) "core.async: every message arrives once"
                  {:producers producers :per per :received (count received)})
      (det/always (every? (fn [[_ messages]] (= (map second messages) (range per))) by-producer)
                  "core.async: each producer's messages arrive in order"
                  {:producers producers :per per}))))

(defn check-core-async-timeout []
  ;; alts! between a value and a timeout: one of them wins, the value is never lost.
  (let [channel (async/chan 1)
        delay-ms (det/random-below 20)
        result (async/<!! (async/go
                            (async/<! (async/timeout delay-ms))
                            (async/>! channel :value)
                            (async/alts! [channel (async/timeout (det/random-below 20))])))]
    (det/always (or (= (first result) :value) (nil? (first result)))
                "core.async: alts! returns the value or the timeout" {:result (pr-str result)})
    (det/sometimes (= (first result) :value) "core.async: alts! took the value")))

(defn check-manifold []
  ;; A stream with concurrent puts and takes delivers every item once.
  (let [count-items (inc (det/random-below 100))
        s (stream/stream (det/random-below 8))
        taken (stream/reduce conj [] s)]
    @(deferred/chain (apply deferred/zip (for [i (range count-items)] (stream/put! s i)))
                     (fn [_] (stream/close! s)))
    (det/always (= (sort @taken) (range count-items)) "manifold: a stream delivers every item once"
                {:items count-items :taken (count @taken)})))

;; The service -------------------------------------------------------------------------------

(def checks {"cheshire" check-cheshire, "jsonista" check-jsonista, "data-json" check-data-json,
             "clj-yaml" check-yaml, "nippy" check-nippy, "malli" check-malli,
             "core-async" check-core-async, "core-async-timeout" check-core-async-timeout,
             "manifold" check-manifold})

(defn handler [request]
  (let [library (subs (:uri request) (count "/check/"))]
    (if-let [check (checks library)]
      (try (check) {:status 200 :body "ok\n"}
           (catch Throwable error
             (det/event "check_threw" {:library library :error (str error)})
             {:status 500 :body (str error "\n")}))
      {:status 404 :body "no such check\n"})))

(defn -main [& _]
  (server/run-server handler {:port 8080 :thread 4})
  (det/setup-complete {:checks (sort (keys checks))})
  @(promise))
