;; SPDX-License-Identifier: MIT
(ns determinismo
  "determinismo SDK for Clojure: assertions, events and platform randomness, with Clojure data.

  It wraps the JVM SDK (sdk/java/Determinismo.java, compiled with your code): inside
  determinismo everything goes through /dev/determinismo (events are recorded with their moment;
  random values are platform decisions, steerable by strategies and replayed by tapes); outside
  it, randomness comes from SecureRandom and events go to stderr. Details are maps (or any data),
  written as JSON: keywords and symbols as strings, other collections as arrays.

    (require '[determinismo :as det])
    (det/always (= 1000 (total)) \"total balance is conserved\" {:total (total)})
    (det/sometimes (empty? queue) \"the queue drains\")
    (det/event \"tla\" {:state {:accounts (vec (vals @accounts))}})
    (det/random-below 10)   ; a platform decision
    (det/choice [:a :b :c]) (det/shuffle accounts) (det/rng)"
  (:refer-clojure :exclude [shuffle])
  (:require [clojure.string :as string]))

;; JSON ------------------------------------------------------------------------------------

(defn- json-string [^String text]
  (let [out (StringBuilder. (+ 2 (.length text)))]
    (.append out \")
    (doseq [c text]
      (case c
        \" (.append out "\\\"")
        \\ (.append out "\\\\")
        \newline (.append out "\\n")
        \return (.append out "\\r")
        \tab (.append out "\\t")
        (if (< (int c) 0x20)
          (.append out (format "\\u%04x" (int c)))
          (.append out c))))
    (.append out \")
    (str out)))

(defn- key-text [k]
  (cond (keyword? k) (if-let [space (namespace k)] (str space "/" (name k)) (name k))
        :else (str k)))

(defn json
  "Clojure data as JSON text: maps as objects, other collections as arrays, keywords and
  symbols as strings, non-finite numbers as null."
  [x]
  (cond (nil? x) "null"
        (string? x) (json-string x)
        (or (keyword? x) (symbol? x)) (json-string (key-text x))
        (boolean? x) (str x)
        (integer? x) (str x)
        (number? x) (let [d (double x)]
                      (if (or (Double/isNaN d) (Double/isInfinite d)) "null" (str d)))
        (map? x) (str "{" (string/join "," (for [[k v] x] (str (json-string (key-text k)) ":" (json v))))
                      "}")
        (coll? x) (str "[" (string/join "," (map json x)) "]")
        :else (json-string (str x))))

;; Assertions ------------------------------------------------------------------------------
;; As Antithesis's: always and always-or-unreachable are judged in every timeline, sometimes
;; and reachable over the multiverse (at least one timeline), unreachable in every timeline.
;;
;; They are macros, so that each one is in the catalog as soon as its code loads, before it
;; runs: the expansion declares it (when the namespace is compiled as it loads, or as the REPL
;; evaluates it), and compiles to a direct call to the JVM SDK with the message as a constant,
;; which DeterminismoCatalog finds in ahead-of-time compiled code. Write messages as literals:
;; one computed at run time is known only once it runs.

(defn details-json
  "Assertion and event details as JSON (nil for none). Used by the macros' expansions."
  ^String [data]
  (when (some? data) (json data)))

(defn- declare!
  "Announces an assertion to the catalog while its code compiles in this JVM (not while AOT
  compiling elsewhere: DeterminismoCatalog reads that bytecode as it loads)."
  [kind message]
  (when (and (string? message) (not *compile-files*))
    (Determinismo/declare kind message)))

(defn- message-form [message]
  (if (string? message) message `(str ~message)))

(defmacro always
  "The condition holds every time this runs, and this runs in some timeline."
  ([condition message] `(always ~condition ~message nil))
  ([condition message data]
   (declare! "always" message)
   `(Determinismo/always (boolean ~condition) ~(message-form message) (details-json ~data))))

(defmacro always-or-unreachable
  "The condition holds every time this runs (never running is fine)."
  ([condition message] `(always-or-unreachable ~condition ~message nil))
  ([condition message data]
   (declare! "always_or_unreachable" message)
   `(Determinismo/alwaysOrUnreachable (boolean ~condition) ~(message-form message)
                                      (details-json ~data))))

(defmacro sometimes
  "The condition holds at least once in some timeline."
  ([condition message] `(sometimes ~condition ~message nil))
  ([condition message data]
   (declare! "sometimes" message)
   `(Determinismo/sometimes (boolean ~condition) ~(message-form message) (details-json ~data))))

(defmacro reachable
  "This runs in some timeline."
  ([message] `(reachable ~message nil))
  ([message data]
   (declare! "reachable" message)
   `(Determinismo/reachable ~(message-form message) (details-json ~data))))

(defmacro unreachable
  "This never runs."
  ([message] `(unreachable ~message nil))
  ([message data]
   (declare! "unreachable" message)
   `(Determinismo/unreachable ~(message-form message) (details-json ~data))))

;; Events and lifecycle --------------------------------------------------------------------

(defn event
  "A named event with data, recorded at its moment (queries, event sets and TLA+ traces read
  them)."
  ([name] (event name nil))
  ([name data] (Determinismo/event name (details-json data))))

(defn setup-complete
  "The system is up: timelines branch from here."
  ([] (setup-complete nil))
  ([data] (Determinismo/setupComplete (details-json data))))

;; Randomness ------------------------------------------------------------------------------
;; Every draw is a platform decision: strategies steer it, tapes replay it.

(defn random-long [] (Determinismo/randomLong))

(defn random-below
  "A uniformly random integer in [0, n)."
  [n]
  (Determinismo/randomBelow (long n)))

(defn choice
  "A random element of a non-empty collection."
  [coll]
  (let [items (vec coll)]
    (when (empty? items) (throw (IllegalArgumentException. "choice of an empty collection")))
    (nth items (random-below (count items)))))

(defn shuffle
  "The collection in a random order (one decision per element)."
  [coll]
  (let [items (object-array coll)]
    (loop [index (dec (alength items))]
      (when (pos? index)
        (let [other (random-below (inc index))
              item (aget items index)]
          (aset items index (aget items other))
          (aset items other item)
          (recur (dec index)))))
    (vec items)))

(defn rng
  "A java.util.Random whose every draw is a platform decision, for code that takes one."
  ^java.util.Random []
  (Determinismo/rng))

(defn prng
  "A java.util.SplittableRandom seeded by one platform decision, for hot loops: fast, and
  replayed, but a strategy steers only its seed."
  ^java.util.SplittableRandom []
  (Determinismo/prng))
