#lang racket

;;; edit-tui/lang/racket/color.rkt —— 增量语法高亮 + 同词着色（纯）
;;;
;;; 缓存单位是“行”：
;;;   lex-states : 每行的出状态（块注释深度 / 是否在字符串里）
;;;   syntax     : 每行的语法 role 向量
;;;   word       : 每行的同词 role 向量
;;;
;;; color-edit 只做：
;;;   1. 按 line-edit 的 old 区间 splice 三组行缓存；
;;;   2. 从最小脏行开始重扫；
;;;   3. 语法状态变化时继续向后推进，直到出状态收敛；
;;;   4. 到达最后一个脏行且状态不变即可停。
;;;
;;; 同词色没有跨行状态，但因为和语法共用一次 tokenize，脏行一起更新。

(provide (struct-out color-state)
         color-open
         color-edit
         color-syntax-roles
         color-word-roles
         color-line-count)

(require racket/list
         racket/string
         "edit.rkt"
         "lex.rkt"
         "highlight.rkt"
         "word-color.rkt")

(struct color-state
  (lex-states   ; vector line -> lex state
   syntax       ; vector line -> (vector role|#f)
   word)        ; vector line -> (vector role|#f)
  #:transparent)

(define (text-lines text)
  (string-split text "\n" #:trim? #f))

(define (color-open text)
  (define lines (text-lines text))
  (let loop ([lines lines] [state empty-lex-state] [states '()] [syntax '()] [word '()])
    (cond
      [(null? lines)
       (color-state (list->vector (reverse states))
                    (list->vector (reverse syntax))
                    (list->vector (reverse word)))]
      [else
       (define line (car lines))
       (define-values (state* tokens) (tokenize-line state line))
       (loop (cdr lines) state*
             (cons state* states)
             (cons (highlight-line tokens line) syntax)
             (cons (word-color-line tokens line) word))])))

(define (color-line-count cache)
  (vector-length (color-state-syntax cache)))

(define (color-syntax-roles cache)
  (vector->list (color-state-syntax cache)))

(define (color-word-roles cache)
  (vector->list (color-state-word cache)))

;; cache 必须对应旧文本；text 是新文本；edits 是旧→新行区间。
(define (color-edit cache text edits)
  (cond
    [(null? edits) cache]
    [else
     (define lines (text-lines text))
     (define n (length lines))
     (define old-states (color-state-lex-states cache))
     (define old-syntax (color-state-syntax cache))
     (define old-word (color-state-word cache))
     (define-values (states0 syntax0 word0)
       (for/fold ([st old-states] [syn old-syntax] [wd old-word])
                 ([sp (in-list (edit-spans edits))])
         (define old-start (car sp))
         (define old-end (cadr sp))
         (define new-count (max 0 (- (cadddr sp) (caddr sp))))
         (values (splice-vector-preserve st old-start old-end new-count)
                 (splice-vector-preserve syn old-start old-end new-count)
                 (splice-vector-preserve wd old-start old-end new-count))))
     (define dirty (edits->dirty-lines edits n))
     (cond
       [(null? dirty) (color-state states0 syntax0 word0)]
       [else
        (define start (car dirty))
        (define last-dirty (car (reverse dirty)))
        (define states* (vector-copy states0))
        (define syntax* (vector-copy syntax0))
        (define word* (vector-copy word0))
        (let loop ([ln start]
                   [incoming (if (and (> start 0)
                                      (< (sub1 start) (vector-length states*)))
                                 (vector-ref states* (sub1 start))
                                 empty-lex-state)])
          (if (>= ln n)
              (color-state states* syntax* word*)
              (let ([line (list-ref lines ln)])
                (define-values (state* tokens) (tokenize-line incoming line))
                (define old-state (if (< ln (vector-length states0))
                                      (vector-ref states0 ln)
                                      #f))
                (vector-set! states* ln state*)
                (vector-set! syntax* ln (highlight-line tokens line))
                (vector-set! word* ln (word-color-line tokens line))
                (define changed? (not (equal? state* old-state)))
                (if (and (>= ln last-dirty) (not changed?))
                    (color-state states* syntax* word*)
                    (loop (add1 ln) state*)))))])]))
