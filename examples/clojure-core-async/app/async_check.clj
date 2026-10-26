;; SPDX-License-Identifier: MIT
;; core.async under test. It runs patched (../core-async.patch): the Clojure SDK's assertions mark
;; its rare paths (closed channels, handoffs to parked peers, alts! peers already done, lock
;; order, reduced transducers, parked puts refilling buffers, go blocks parking and throwing,
;; shared timeouts), buggify points widen its race windows, and the order alts! tries its ports
;; in is a platform decision. This service exercises it, one request per connection, each on its
;; own thread, every choice a platform decision:
;;   "channels" producers and consumers on one channel (unbuffered, fixed, dropping, sliding, or
;;              with a take transducer), blocking or parking.
;;   "alts"     producers and consumers over several channels through alts! (priority, default).
;;   "pipeline" pipeline, pipeline-blocking and pipeline-async.
;;   "mult"     a mult and its taps.
;;   "go"       go blocks parking inside try, catch and finally.
;;   "timeout"  timeouts from several go blocks.
;; Replies: "ok" or "error <message>".
(ns async-check
  (:require [clojure.core.async :as a]
            [clojure.string :as string]
            [determinismo :as det]) ; sdk/clojure, over sdk/java
  (:import [java.net ServerSocket]
           [java.io BufferedReader InputStreamReader PrintWriter]))

(defn pick
  "A platform decision among n, named for strategies."
  [name n]
  (det/random-below-named name n))

(defn sized-chan
  "An unbuffered channel for 0, else a fixed buffer of n."
  [n]
  (if (zero? n) (a/chan) (a/chan n)))

(defn per-producer-increasing?
  "Within each producer, the values' sequence numbers increase."
  [values]
  (every? (fn [[_ items]] (or (empty? (rest items)) (apply < (map second items))))
          (group-by first values)))

;; --- One channel ----------------------------------------------------------------------------

(defn channels-check []
  (let [kind (pick "channel kind" 5)
        size (inc (pick "channel buffer size" 8))
        limit (inc (pick "channel take limit" 20))
        ch (case kind
             0 (a/chan)
             1 (a/chan size)
             2 (a/chan (a/dropping-buffer size))
             3 (a/chan (a/sliding-buffer size))
             4 (a/chan size (take limit)))
        producers (inc (pick "channel producers" 4))
        per (inc (pick "channel values per producer" 30))
        consumers (inc (pick "channel consumers" 4))
        parking (zero? (pick "channel go blocks" 2))
        accepted (atom [])
        received (vec (repeatedly consumers #(atom [])))
        produce (fn [p]
                  (if parking
                    (a/<!! (a/go (dotimes [i per]
                                   (when (a/>! ch [p i]) (swap! accepted conj [p i])))))
                    (dotimes [i per]
                      (when (a/>!! ch [p i]) (swap! accepted conj [p i])))))
        consume (fn [c]
                  (loop []
                    (when-some [value (if parking (a/<!! (a/go (a/<! ch))) (a/<!! ch))]
                      (swap! (received c) conj value)
                      (recur))))
        consumer-threads (doall (for [c (range consumers)] (future (consume c))))]
    (run! deref (doall (for [p (range producers)] (future (produce p)))))
    (a/close! ch)
    (run! deref consumer-threads)
    (let [all (mapcat deref received)]
      (det/always (= (count all) (count (set all)))
                  "core.async: no value is received twice" {:kind kind})
      (det/always (every? #(per-producer-increasing? @%) received)
                  "core.async: each consumer gets a producer's values in the order put"
                  {:kind kind})
      (when (#{0 1} kind)
        (det/always (= (sort @accepted) (sort all))
                    "core.async: an unbuffered or fixed channel delivers each accepted value"
                    {:kind kind :accepted (count @accepted) :received (count all)}))
      (when (= 4 kind)
        (det/always (<= (count all) limit)
                    "core.async: a take transducer passes no more than its limit"
                    {:limit limit :received (count all)})))
    "ok"))

;; --- alts! over several channels -------------------------------------------------------------

(defn alts-check []
  (let [channels (vec (repeatedly (+ 2 (pick "alts channels" 3))
                                  #(if (zero? (pick "alts buffered" 2))
                                     (a/chan)
                                     (a/chan (inc (pick "alts buffer size" 4))))))
        producers (inc (pick "alts producers" 3))
        per (inc (pick "alts values per producer" 20))
        priority (zero? (pick "alts priority" 2))
        sent (atom [])
        received (atom [])
        produce (fn [p]
                  (a/<!! (a/go
                           (dotimes [i per]
                             (let [[ok port] (a/alts! (mapv (fn [c] [c [p i]]) channels)
                                                      :priority priority)]
                               (when ok (swap! sent conj [p i (.indexOf ^java.util.List channels port)])))))))
        consume (fn []
                  (loop [open (set channels)]
                    (when (seq open)
                      (let [[value port] (if (zero? (pick "alts default" 4))
                                           (a/alts!! (vec open) :default ::none)
                                           (a/alts!! (vec open)))]
                        (cond
                          (= port :default) (do (Thread/sleep 1) (recur open))
                          (nil? value) (recur (disj open port))
                          :else (do (swap! received conj value) (recur open)))))))
        consumers (doall (repeatedly (inc (pick "alts consumers" 3)) #(future (consume))))]
    (run! deref (doall (for [p (range producers)] (future (produce p)))))
    (run! a/close! channels)
    (run! deref consumers)
    (det/always (= (sort (map (fn [[p i _]] [p i]) @sent)) (sort @received))
                "core.async: each value an alts! put is received once"
                {:sent (count @sent) :received (count @received)})
    "ok"))

;; --- Pipelines -------------------------------------------------------------------------------

(defn pipeline-check []
  (let [n (pick "pipeline length" 60)
        parallelism (inc (pick "pipeline parallelism" 6))
        kind (pick "pipeline kind" 3)
        from (a/to-chan! (range n))
        to (sized-chan (pick "pipeline buffer" 4))
        f (fn [x] (when (zero? (pick "pipeline slow" 4)) (Thread/sleep (pick "pipeline ms" 5)))
            (* x x))]
    (case kind
      0 (a/pipeline parallelism to (map f) from)
      1 (a/pipeline-blocking parallelism to (map f) from)
      2 (a/pipeline-async parallelism to
                          (fn [x out]
                            (a/go (a/<! (a/timeout (pick "pipeline async ms" 5)))
                                  (a/>! out (* x x))
                                  (a/close! out)))
                          from))
    (let [out (a/<!! (a/into [] to))]
      (det/always (= out (mapv #(* % %) (range n)))
                  "core.async: a pipeline's output keeps its input's order"
                  {:kind kind :n n :got (count out)}))
    "ok"))

;; --- mult ------------------------------------------------------------------------------------

(defn mult-check []
  (let [n (pick "mult values" 40)
        source (sized-chan (pick "mult source buffer" 4))
        m (a/mult source)
        taps (vec (repeatedly (inc (pick "mult taps" 4))
                              #(a/tap m (sized-chan (pick "mult tap buffer" 4)))))
        readers (mapv (fn [tap] (a/go-loop [seen []]
                                  (if-some [v (a/<! tap)] (recur (conj seen v)) seen)))
                      taps)]
    (a/<!! (a/onto-chan! source (range n)))
    (let [seen (mapv a/<!! readers)]
      (det/always (every? #(= % (vec (range n))) seen)
                  "core.async: every tap of a mult receives every value, in order"
                  {:n n :seen (mapv count seen)}))
    "ok"))

;; --- pub/sub ---------------------------------------------------------------------------------

(defn pubsub-check
  "Publishers put [topic producer i] on a pub's source; subscribers, all subscribed before, take
  until their channels close: each gets exactly its topics' values, a producer's in order. One
  channel per topic: a channel shared by topics closes with the first topic's mult (close?),
  which may still drop the other topics' last values, by design."
  []
  (let [topics (+ 2 (pick "pubsub topics" 4))
        source (sized-chan (pick "pubsub source buffer" 4))
        p (if (zero? (pick "pubsub topic buffers" 2))
            (a/pub source first)
            (a/pub source first (fn [_topic] (inc (pick "pubsub topic buffer" 4)))))
        subscribers (vec (for [_ (range (inc (pick "pubsub subscribers" 4)))]
                           (let [wanted (set (filter (fn [_] (zero? (pick "pubsub wants" 2)))
                                                     (range topics)))
                                 readers (doall
                                          (for [topic wanted]
                                            (let [ch (sized-chan (pick "pubsub sub buffer" 4))]
                                              (a/sub p topic ch)
                                              (a/go-loop [got []]
                                                (if-some [v (a/<! ch)] (recur (conj got v)) got)))))]
                             {:wanted wanted
                              :got (a/go (loop [rs readers got []]
                                           (if (seq rs)
                                             (recur (rest rs) (into got (a/<! (first rs))))
                                             got)))})))
        producers (inc (pick "pubsub producers" 3))
        per (inc (pick "pubsub values per producer" 20))
        sent (vec (for [producer (range producers) i (range per)]
                    [(pick "pubsub topic" topics) producer i]))]
    (when (empty? (filter #(seq (:wanted %)) subscribers))
      (det/sometimes true "core.async pub: no subscriber wanted any topic" {}))
    (run! deref (doall (for [producer (range producers)]
                         (future (doseq [v sent :when (= producer (second v))]
                                   (a/>!! source v))))))
    (a/close! source)
    (doseq [{:keys [wanted got]} subscribers]
      (let [got (a/<!! got)
            expected (filter #(contains? wanted (first %)) sent)]
        (det/always (and (= (sort got) (sort expected))
                         (every? (fn [[_ items]] (or (empty? (rest items))
                                                     (apply < (map #(nth % 2) items))))
                                 (group-by (juxt first second) got)))
                    "core.async pub: each subscriber gets exactly its topics' values, in order"
                    {:wanted wanted :got (count got) :expected (count expected)})))
    "ok"))

;; --- put!/take! callbacks, offer!/poll! -------------------------------------------------------

(defn callbacks-check
  "Producers put! with callbacks (or offer!), consumers take! with callbacks (or poll!), then the
  channel closes and drains: what was taken is exactly what was accepted, nothing twice."
  []
  (let [ch (sized-chan (pick "callbacks buffer" 4))
        producers (inc (pick "callbacks producers" 4))
        per (inc (pick "callbacks values per producer" 20))
        accepted (atom [])
        taken (atom [])
        pending (atom 0) ; put!s and take!s whose callbacks have not run yet
        produce (fn [producer]
                  (dotimes [i per]
                    (let [v [producer i]]
                      (if (zero? (pick "callbacks offer" 3))
                        (when (a/offer! ch v) (swap! accepted conj v))
                        (let [done (promise)]
                          (swap! pending inc)
                          (a/put! ch v (fn [ok]
                                         (when ok (swap! accepted conj v))
                                         (swap! pending dec)
                                         (deliver done ok))
                                  (zero? (pick "callbacks on caller" 2)))
                          ;; Parked puts complete as consumers take; don't wait on them all.
                          (when (zero? (pick "callbacks wait for the put" 2))
                            (deref done 200 nil)))))))
        consume (fn []
                  (dotimes [_ (* 2 per)]
                    (if (zero? (pick "callbacks poll" 3))
                      (when-some [v (a/poll! ch)] (swap! taken conj v))
                      (let [got (promise)]
                        (swap! pending inc)
                        ;; The callback records what it gets: a take given up on still counts.
                        (a/take! ch (fn [v]
                                      (when (some? v) (swap! taken conj v))
                                      (swap! pending dec)
                                      (deliver got v)))
                        (deref got 50 nil)))))]
    (run! deref (doall (concat (for [p (range producers)] (future (produce p)))
                               (for [_ (range (inc (pick "callbacks consumers" 3)))]
                                 (future (consume))))))
    (a/close! ch)
    ;; Takes still parked (their promise given up) get nil once closed and drained; the rest
    ;; drains here.
    (loop [] (when-some [v (a/<!! ch)] (swap! taken conj v) (recur)))
    (loop [waited 0] ; Every callback issued runs: closed, nothing stays parked.
      (when (and (pos? @pending) (< waited 5000))
        (Thread/sleep 10)
        (recur (+ waited 10))))
    (det/always (zero? @pending) "core.async: every put! and take! callback runs once closed"
                {:pending @pending})
    (det/always (= (sort @accepted) (sort @taken))
                "core.async: what put! and offer! had accepted is taken, each once"
                {:accepted (count @accepted) :taken (count @taken)})
    "ok"))

;; --- go blocks: parking in try, catch and finally --------------------------------------------

(defn go-check []
  (let [n (inc (pick "go blocks" 12))
        in (a/chan)
        done (a/chan n)
        finals (atom 0)
        blocks (doall
                (for [i (range n)]
                  (a/go
                    (try
                      (let [v (a/<! in)]
                        (when (odd? v) (throw (ex-info "odd" {:v v})))
                        [:even v])
                      (catch clojure.lang.ExceptionInfo e
                        (a/<! (a/timeout (pick "go catch ms" 3)))
                        [:odd (:v (ex-data e))])
                      (finally
                        (swap! finals inc)
                        (a/>! done i))))))]
    (dotimes [v n] (a/>!! in v))
    (let [results (mapv a/<!! blocks)
          finished (a/<!! (a/into #{} (a/take n done)))]
      (det/always (= (sort (map second results)) (range n))
                  "core.async: each go block's try or catch gives its value after a park"
                  {:results results})
      (det/always (every? (fn [[kind v]] (= kind (if (odd? v) :odd :even))) results)
                  "core.async: an exception thrown after a park reaches its go block's catch"
                  {:results results})
      (det/always (and (= n @finals) (= finished (set (range n))))
                  "core.async: a go block's finally runs once, parking included"
                  {:finals @finals :finished (count finished)}))
    "ok"))

;; --- Timeouts --------------------------------------------------------------------------------

(defn timeout-check []
  (let [waits (mapv (fn [_] (pick "timeout ms" 40)) (range (inc (pick "timeouts" 8))))
        early (a/<!! (a/into []
                             (a/merge
                              (for [ms waits]
                                (a/go (let [start (System/currentTimeMillis)]
                                        (a/<! (a/timeout ms))
                                        (when (< (- (System/currentTimeMillis) start) ms)
                                          [ms (- (System/currentTimeMillis) start)])))))))]
    (det/always (empty? early) "core.async: a timeout never fires early" {:early early})
    "ok"))

;; --- Service ---------------------------------------------------------------------------------

(defn handle [socket]
  (with-open [socket socket
              in (BufferedReader. (InputStreamReader. (.getInputStream socket)))
              out (PrintWriter. (.getOutputStream socket) true)]
    (.println out
              (try
                (case (string/trim (or (.readLine in) ""))
                  "channels" (channels-check)
                  "alts" (alts-check)
                  "pipeline" (pipeline-check)
                  "mult" (mult-check)
                  "pubsub" (pubsub-check)
                  "callbacks" (callbacks-check)
                  "go" (go-check)
                  "timeout" (timeout-check)
                  "unknown")
                (catch Throwable thrown
                  (str "error " (.getName (class thrown)) " " (.getMessage thrown)))))))

(defn -main [& _arguments]
  ;; core.async's own assertions sit on hot paths: their first pass and first failure are enough.
  (det/first-pass-first-failure!)
  (let [server (ServerSocket. 7200)]
    (loop []
      (let [socket (.accept server)]
        (future (handle socket)))
      (recur))))
