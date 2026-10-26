;; SPDX-License-Identifier: MIT
;; The Clojure compiler and runtime under test. They run patched (../clojure.patch): the Java
;; SDK's assertions mark their rare paths, which guide the exploration there, and buggify points
;; widen their race windows. This service exercises them, one request per connection, each on
;; its own thread, all choices platform decisions:
;;   "stm"   transfers between refs (alter, commute, ensure, a validator), an agent sent to from
;;           inside each transaction: the total is conserved in every snapshot, and each commit
;;           ran its agent action once.
;;   "skew"  two accounts whose sum stays above a floor, each withdrawal ensuring the other one:
;;           ensure rules out write skew, so the floor holds.
;;   "form"  a generated form, evaluated with each compiler option set: the same printed result
;;           (or the same exception) under all of them, and bytecode the JVM accepts.
;;   "lazy"  one lazy seq realized from several threads at once: the same elements in each.
;; Replies: "ok" or "error <message>".
(ns compiler-check
  (:require [clojure.string :as string]
            [determinismo :as det]) ; sdk/clojure, over sdk/java
  (:import [java.net ServerSocket]
           [java.io BufferedReader InputStreamReader PrintWriter]))

(defn pick
  "A platform decision among n, named for strategies."
  [name n]
  (det/random-below-named name n))

;; --- STM ------------------------------------------------------------------------------------

(def account-count 8)
(def balance 100)
(def total (* account-count balance))

(defonce accounts
  (vec (repeatedly account-count #(ref balance :validator (fn [value] (>= value 0))))))

(defn snapshot-total [] (dosync (reduce + (map deref accounts))))

(defn transfer!
  "Moves amount from one account to another the way `how` says (alter or commute the
  receiver, ensuring it before or after), and sends the request's agent an increment from
  inside the transaction (dispatched once, at commit). True when it moved. A careless transfer
  skips the balance check: the validator then aborts it, and its send with it."
  [from to amount how careless applied]
  (try
    (dosync
     (when (#{:ensure :ensure-commute} how) (ensure (accounts to)))
     (when (or careless (>= @(accounts from) amount))
       (alter (accounts from) - amount)
       (if (#{:commute :ensure-commute} how)
         (commute (accounts to) + amount)
         (alter (accounts to) + amount))
       (when (= how :ensure-written) (ensure (accounts to)))
       (send applied inc)
       true))
    (catch IllegalStateException _invalid
      (det/sometimes true "STM: a validator rejected a transaction's value" {})
      false)))

(defn stm-check []
  (let [threads (inc (pick "stm threads" 6))
        transfers (inc (pick "stm transfers per thread" 20))
        applied (agent 0)
        committed (atom 0)
        work (fn []
               (dotimes [_ transfers]
                 (let [from (pick "stm from" account-count)
                       to (mod (+ from 1 (pick "stm to" (dec account-count))) account-count)
                       amount (inc (pick "stm amount" 60))
                       how ([:alter :commute :ensure :ensure-commute :ensure-written]
                            (pick "stm how" 5))
                       careless (zero? (pick "stm careless" 8))]
                   (when (transfer! from to amount how careless applied)
                     (swap! committed inc)))
                 (det/always (= total (snapshot-total))
                             "STM: the total is conserved in every snapshot" {})))]
    (run! deref (doall (repeatedly threads #(future (work)))))
    (await applied)
    (det/always (= @committed @applied)
                "STM: each commit ran its transaction's agent send once"
                {:committed @committed :applied @applied})
    "ok"))

;; Write skew: x + y must stay at or above the floor. A withdrawal from one checks the sum with
;; the other ensured, so a concurrent withdrawal from the other cannot slip in between.
(def floor-sum 100)
(defonce skew-x (ref 100))
(defonce skew-y (ref 100))

(defn withdraw! [from other amount]
  (dosync
   (ensure other)
   (when (>= (- (+ @from @other) amount) floor-sum)
     (alter from - amount))))

(defn skew-check []
  (let [threads (+ 2 (pick "skew threads" 4))
        work (fn []
               (dotimes [_ (inc (pick "skew withdrawals" 6))]
                 (let [x? (zero? (pick "skew account" 2))
                       amount (inc (pick "skew amount" 40))]
                   (if x?
                     (withdraw! skew-x skew-y amount)
                     (withdraw! skew-y skew-x amount)))
                 (let [sum (dosync (+ @skew-x @skew-y))]
                   (det/always (>= sum floor-sum)
                               "STM: ensure prevents write skew (the floor holds)"
                               {:sum sum}))))]
    (run! deref (doall (repeatedly threads #(future (work)))))
    ;; Refill, so later requests withdraw again.
    (dosync (ref-set skew-x 100) (ref-set skew-y 100))
    "ok"))

;; --- Generated forms ------------------------------------------------------------------------

;; Strings whose String.hashCode collide ("Aa" and "BB", and their concatenations): map keys
;; that share collision nodes, case constants that need sequential checks.
(def colliding ["Aa" "BB" "AaAa" "AaBB" "BBAa" "BBBB"])

(declare form)

(defn literal []
  (case (pick "form literal" 4)
    0 (pick "form small long" 10)
    1 (- (pick "form long" 2000) 1000)
    2 (+ 0.5 (pick "form double" 8))
    3 Long/MAX_VALUE))

(defn operand [depth locals]
  (if (and (seq locals) (zero? (pick "form use a local" 2)))
    (locals (pick "form which local" (count locals)))
    (form (dec depth) locals)))

(defn form
  "A number-valued form: arithmetic, locals (some primitive), loops, closures, case over
  colliding hashes, collections with colliding keys, reflective interop."
  [depth locals]
  (if (<= depth 0)
    (literal)
    (let [a #(operand depth locals)
          local (symbol (str "x" (count locals)))
          inner #(form (dec depth) (conj locals local))]
      (case (pick "form shape" 12)
        0 (list (['+' '-' '*' 'max 'min] (pick "form arithmetic" 5)) (a) (a))
        1 (list 'let [local (a)] (inner))
        ;; A primitive long local (its initializer is one; a hint on it is refused).
        2 (list 'let [local (list 'long (list 'min 1000000 (list 'max -1000000 (a))))]
                (inner))
        3 (list 'if (list (['< '= '>] (pick "form comparison" 3)) (a) (a)) (a) (a))
        ;; A long loop local the body may recur with a double: re-analyzed boxed.
        4 (list 'loop [local 0 'n (pick "form loop count" 5)]
                (list 'if (list 'pos? 'n)
                      (list 'recur (list '+' local (form (dec depth) (conj locals local))) (list 'dec 'n))
                      local))
        5 (list (list 'fn [local] (inner)) (a))
        ;; Once-only closures (delay, lazy-seq): locals clearing.
        6 (list 'deref (list 'delay (a)))
        7 (list 'first (list 'lazy-seq (list 'cons (a) nil)))
        8 (list 'case (list 'colliding (list 'mod (list 'long (list 'min 1000 (list 'max -1000 (a)))) 6))
                "Aa" (a) "BB" (a) "AaAa" (a) "BBBB" (a) (a))
        ;; Maps over colliding keys, persistent and transient, grown and shrunk.
        9 (list 'count
                (list 'reduce 'dissoc
                      (list 'zipmap 'colliding (list 'repeat (a)))
                      (vec (take (pick "form dissoc count" 6) colliding))))
        10 (list 'count
                 (list 'persistent!
                       (list 'reduce (list 'fn ['m 'k] (list 'assoc! 'm 'k 'k))
                             (list 'transient {})
                             (list 'range (pick "form map size" 40)))))
        ;; Reflection: an untyped local through an overloaded static method.
        11 (list 'let ['o (list 'identity (a))]
                 (list 'Math/abs 'o))))))

(def option-sets
  [{}
   {:direct-linking true}
   {:disable-locals-clearing true}
   {:direct-linking true :disable-locals-clearing true}])

(defn compiler-bug?
  "The JVM rejected emitted bytecode, or the compiler itself failed (not the form)."
  [^Throwable thrown]
  (some (fn [^Throwable cause]
          (or (instance? LinkageError cause) ; VerifyError, ClassFormatError, ...
              (and (or (instance? NullPointerException cause)
                       (instance? IndexOutOfBoundsException cause)
                       (instance? ClassCastException cause))
                   (some-> (first (.getStackTrace cause)) .getClassName
                           (string/starts-with? "clojure.lang.Compiler")))))
        (take-while some? (iterate #(.getCause ^Throwable %) thrown))))

(defn outcome [options generated]
  (try
    (binding [*compiler-options* options
              *ns* (the-ns 'compiler-check)]
      (pr-str (eval generated)))
    (catch Throwable thrown
      (det/always (not (compiler-bug? thrown))
                  "the compiler emits bytecode the JVM accepts, and does not fail itself"
                  {:form (pr-str generated) :options options :error (str thrown)})
      (str "threw " (.getName (class (if (instance? clojure.lang.Compiler$CompilerException thrown)
                                       (or (.getCause thrown) thrown)
                                       thrown)))))))

(defn form-check []
  (let [generated (form (inc (pick "form depth" 4)) [])
        outcomes (mapv #(outcome % generated) option-sets)]
    (det/always (apply = outcomes)
                "a form gives the same result whatever the compiler options"
                {:form (pr-str generated) :outcomes outcomes})
    "ok"))

;; --- Lazy seqs ------------------------------------------------------------------------------

(defn numbers [i limit]
  (lazy-seq (when (< i limit) (cons (* i i) (numbers (inc i) limit)))))

(defn lazy-check []
  (let [limit (pick "lazy length" 80)
        shared (if (zero? (pick "lazy chunked" 2))
                 (map #(* % %) (range limit)) ; chunked (32 at a time)
                 (numbers 0 limit))
        results (mapv deref (doall (repeatedly (+ 2 (pick "lazy readers" 4))
                                               #(future (vec shared)))))]
    (det/always (apply = results)
                "a lazy seq realized by several threads gives each the same elements"
                {:limit limit :counts (mapv count results)})
    "ok"))

;; --- Service --------------------------------------------------------------------------------

(defn handle [socket]
  (with-open [socket socket
              in (BufferedReader. (InputStreamReader. (.getInputStream socket)))
              out (PrintWriter. (.getOutputStream socket) true)]
    (.println out
              (try
                (case (string/trim (or (.readLine in) ""))
                  "stm" (stm-check)
                  "skew" (skew-check)
                  "form" (form-check)
                  "lazy" (lazy-check)
                  "unknown")
                (catch Throwable thrown
                  (str "error " (.getName (class thrown)) " " (.getMessage thrown)))))))

(defn -main [& _arguments]
  (let [server (ServerSocket. 7100)]
    (loop []
      (let [socket (.accept server)]
        (future (handle socket)))
      (recur))))
