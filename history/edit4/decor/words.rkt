#lang racket

;;; edit4/decor/words.rkt —— 光标所在词高亮装饰（增量）
;;;
;;; 只把「光标所在 token」涂 'word-mark。状态 = 上次光标；change 只重扫
;;; 「旧光标行 ∪ 新光标行 ∪ 本编辑波及行」——其余行结构共享。

(provide words-decor words-line)

(require racket/list
         "lex.rkt"
         "protocol.rkt"
         "dirty.rkt"
         (only-in "../../core/text/base/track.rkt" track-length track-ref track-splice))

;; 一行 → face 向量：光标在该行且落在某 token 内（或紧跟词尾）就整段涂。
(define (words-line cursor ln line)
  (define vec (make-vector (string-length line) #f))
  (when (and cursor (= ln (car cursor)))
    (define cc (cdr cursor))
    (for ([m (in-list (line-tokens line))])
      (when (and (<= (car m) cc) (<= cc (cdr m)))
        (for ([j (in-range (car m) (cdr m))]) (vector-set! vec j 'word-mark)))))
  vec)

(define words-decor
  (decor
   ;; 首扫无光标 → 全 #f 层。
   (lambda (_path text)
     (values #f (scan-track text (lambda (ln line) (words-line #f ln line)))))
   (lambda (state layer ctx)
     (define changes (face-ctx-changes ctx))
     (define cursor (face-ctx-cursor ctx))
     (cond
       ;; 无编辑且光标未动 → 不重扫（帧间空转）
       [(and (null? changes) (equal? state cursor)) (values state layer (dirty-lines '()))]
       [else
        (define text (face-ctx-new-text ctx))
        (define old-line (and state (car state)))
        (define new-line (and cursor (car cursor)))
        (define extra (filter values (list old-line new-line)))
        (values cursor
                (refresh-layer layer text changes extra
                               (lambda (ln line) (words-line cursor ln line)))
                (dirty-union (face-ctx-dirty ctx) (dirty-lines extra)))]))))
