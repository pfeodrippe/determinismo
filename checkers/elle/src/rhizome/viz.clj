;; SPDX-License-Identifier: MIT
;; A stand-in for rhizome.viz (ahead of the real one on the classpath): the real one sets Swing
;; up as it loads, which fails on a headless JVM. Elle draws only into the :directory it is given,
;; and the service gives none, so nothing here is ever called.
(ns rhizome.viz)

(defn- no-drawing [& _]
  (throw (UnsupportedOperationException. "elle-service does not draw")))

(def dot->image no-drawing)
(def dot->svg no-drawing)
(def save-image no-drawing)
(def view-image no-drawing)
