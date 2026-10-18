#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯：text -> state/layer）
;;;
;;; words-decor.rkt —— 光标所在 token 的背景高亮（增量）
;;;
;;; 状态 = 上次光标。光标移动只重扫旧光标行 / 新光标行；
;;; 文本编辑时 changes 波及的行也要重扫。与 edit4/decor/words.rkt 同构。

(provide words-face-decor)

(require (except-in racket/list range)
         "../../model/face-decor.rkt"
         "../../model/face-layer.rkt"
         "lex.rkt")

(define (words-line cursor ln line)
  (define vec (make-vector (string-length line) #f))
  (when (and cursor (= ln (car cursor)))
    (define cc (cdr cursor))
    (define n (string-length line))
    (let loop ([i 0])
      (cond
        [(>= i n) (void)]
        [(symbol-char? (string-ref line i))
         (define end (let next ([j (add1 i)])
                       (if (and (< j n) (symbol-char? (string-ref line j))) (next (add1 j)) j)))
         (when (and (<= i cc) (<= cc end))
           (for ([k (in-range i end)])
             (vector-set! vec k (face-set-bg face-empty 'bg-word-mark))))
         (loop end)]
        [else (loop (add1 i))])))
  vec)

(define (words-open _path text)
  (values #f (scan-track text (lambda (ln line) (words-line #f ln line)))))

(define (words-change state layer ctx)
  (define changes (face-ctx-changes ctx))
  (define cursor (face-ctx-cursor ctx))
  (cond
    [(and (null? changes) (equal? state cursor))
     (values state layer (dirty-lines '()))]
    [else
     (define text (face-ctx-new-text ctx))
     (define old-line (and state (car state)))
     (define new-line (and cursor (car cursor)))
     (define extra (filter values (list old-line new-line)))
     (values cursor
             (refresh-layer layer text changes extra
                            (lambda (ln line) (words-line cursor ln line)))
             (dirty-union (face-ctx-dirty ctx) (dirty-lines extra)))]))

(define words-face-decor
  (face-decor 'words 'words (lambda (_dm) #t) words-open words-change))
