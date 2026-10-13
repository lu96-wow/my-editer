#lang racket

;;; edit4/plugins/sync/mark.rkt —— 光标所在「映射词」高亮（decor，纯）
;;;
;;; 光标落在某个词上、且该词在词表里 → 整个 token 涂 'sync-mark。
;;; 与 view 同步配合：光标在两篇文档间是按映射搬过去的，所以两边高亮的正是「对应词」。
;;; 由插件 #:applies? 门控，只作用于无 path 的内存文档（同步文档就是内存文档）。

(provide sync-mark-decor)

(require racket/list
         "../../decor/lex.rkt"
         "../../decor/protocol.rkt"
         "../../decor/dirty.rkt"
         "mapping.rkt")

(define (mark-line cursor ln line)
  (define vec (make-vector (string-length line) #f))
  (when (and cursor (= ln (car cursor)))
    (define cc (cdr cursor))
    (for ([m (in-list (line-tokens line))])
      (when (and (<= (car m) cc) (<= cc (cdr m))
                 (mapped-term? (substring line (car m) (cdr m))))
        (for ([j (in-range (car m) (cdr m))]) (vector-set! vec j 'sync-mark)))))
  vec)

(define sync-mark-decor
  (decor
   (lambda (_path text)
     (values #f (scan-track text (lambda (ln line) (mark-line #f ln line)))))
   (lambda (state layer ctx)
     (define changes (face-ctx-changes ctx))
     (define cursor (face-ctx-cursor ctx))
     (cond
       [(and (null? changes) (equal? state cursor)) (values state layer (dirty-lines '()))]
       [else
        (define text (face-ctx-new-text ctx))
        (define old-line (and state (car state)))
        (define new-line (and cursor (car cursor)))
        (define extra (filter values (list old-line new-line)))
        (values cursor
                (refresh-layer layer text changes extra
                               (lambda (ln line) (mark-line cursor ln line)))
                (dirty-union (face-ctx-dirty ctx) (dirty-lines extra)))]))))
