#lang racket
(require (file "../core/editor.rkt"))
(define-values (vars stxs) (module->exports '(file "../core/editor.rkt")))
(printf "VARS ~s\n" (map car vars))
(printf "STXS ~s\n" (map car stxs))
