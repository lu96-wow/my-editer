#lang racket

(require racket/string
         "../../core/text/base/line.rkt"
         "api.rkt"
         "registry.rkt"
         "shadow.rkt")

;;; lab/plugin/machine.rkt —— 插件状态机（同步 runner 与 place worker 共用）
;;;
;;; 维护每个 did 的 **影子文本（按 token）** + **各插件的状态与全量 fills（最新 token）**：
;;;   open!    did token path text   建立影子 + 各插件 plugin-open
;;;   change!  did from to path edits 影子增量 → 各插件 plugin-change（增量）
;;;   job      did token name path   取该 token 的全量 fills（不在最新 token 就整篇重算）
;;;   drop!/close!
;;;
;;; undo/redo 回到旧 token 时 manager 不会派 job（结果已缓存），所以状态只需保最新 token。

(provide make-machine
         machine-open! machine-change! machine-drop! machine-close! machine-job)

(struct machine (shadows latest) #:transparent)
;; shadows : hash did -> hash token -> (vectorof string)
;; latest  : hash did -> (cons token (hash name -> (cons state fills)))

(define (make-machine) (machine (make-hash) (make-hash)))

(define (shadow-table m did)
  (or (hash-ref (machine-shadows m) did #f)
      (let ([h (make-hash)]) (hash-set! (machine-shadows m) did h) h)))

(define (open-states! text path)
  (define st (make-hash))
  (for ([p (in-list registry-plugins)])
    (define-values (s fl) ((plugin-open p) text path))
    (hash-set! st (plugin-name p) (cons s fl)))
  st)

(define (machine-open! m did token path text)
  (hash-set! (shadow-table m did) token (list->vector (string->lines text)))
  (hash-set! (machine-latest m) did (cons token (open-states! text path))))

(define (machine-change! m did from to path edits)
  (define tbl (shadow-table m did))
  (define lines (shadow-apply (hash-ref tbl from) edits))
  (hash-set! tbl to lines)
  (define cur (hash-ref (machine-latest m) did #f))
  (cond
    ;; 从最新 token 增量：把每个插件的状态推进到 to
    [(and cur (eqv? (car cur) from))
     (define st (cdr cur))
     (for ([p (in-list registry-plugins)])
       (define old (hash-ref st (plugin-name p)))
       (define-values (s fl) ((plugin-change p) (car old) edits lines path))
       (hash-set! st (plugin-name p) (cons s fl)))
     (hash-set! (machine-latest m) did (cons to st))]
    ;; 其它（分支 / redo）→ 整篇重开
    [else
     (hash-set! (machine-latest m) did
                (cons to (open-states! (lines->string (vector->list lines)) path)))]))

(define (machine-drop! m did token)
  (hash-remove! (shadow-table m did) token))

(define (machine-close! m did)
  (hash-remove! (machine-shadows m) did)
  (hash-remove! (machine-latest m) did))

;; 取该 token 某插件的全量 fills；不在最新 token 就整篇重算。
(define (machine-job m did token name path)
  (define cur (hash-ref (machine-latest m) did #f))
  (cond
    [(and cur (eqv? (car cur) token))
     (define e (hash-ref (cdr cur) name #f))
     (and e (cdr e))]
    [else
     (define lines (hash-ref (shadow-table m did) token #f))
     (define p (registry-ref name))
     (and lines p
          (let-values ([(s fl) ((plugin-open p) (lines->string (vector->list lines)) path)])
            fl))]))
