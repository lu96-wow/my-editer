#lang racket

;;; edit-tui/lang/racket/color/color.rkt —— 增量语法高亮 + 同词着色 + 括号深度（纯）
;;;
;;; 缓存单位是“行”：
;;;   lex-out-states     : 每行的出状态（块注释深度 / 是否在字符串里）
;;;   bracket-out-states : 每行的出括号栈
;;;   syntax-roles       : 每行的语法 role 向量
;;;   word-roles         : 每行的同词 role 向量
;;;   bracket-roles      : 每行的括号深度 role 向量
;;;
;;; color-edit 只做：
;;;   1. 按 line-edit 的 old 区间 splice 五组行缓存；
;;;   2. 从最小脏行开始重扫；
;;;   3. 词法状态或括号栈变化时继续向后推进，直到两个出状态都收敛；
;;;   4. 到达最后一个脏行且状态不变即可停。
;;;
;;; 同词色没有跨行状态，但因为和语法 / 括号共用一次 tokenize，脏行一起更新。

(provide (struct-out color-state)
         color-open
         color-edit
         color-syntax-roles
         color-word-roles
         color-bracket-roles
         color-line-count)

(require racket/list
         racket/string
         "../base/edit.rkt"
         "../base/lex.rkt"
         "highlight.rkt"
         "word-color.rkt"
         "bracket.rkt")

(struct color-state
  (lex-out-states     ; vector line -> 行尾词法状态
   bracket-out-states ; vector line -> 行尾括号栈
   syntax-roles       ; vector line -> (vector role|#f)
   word-roles         ; vector line -> (vector role|#f)
   bracket-roles)     ; vector line -> (vector role|#f)
  #:transparent)

(define (text-lines text)
  (string-split text "\n" #:trim? #f))

(define (color-open text)
  (define lines (text-lines text))
  (let loop ([lines lines]
             [state empty-lex-state]
             [bracket '()]
             [states '()]
             [bracket-states '()]
             [syntax '()]
             [word '()]
             [bracket-roles '()])
    (cond
      [(null? lines)
       (color-state (list->vector (reverse states))
                    (list->vector (reverse bracket-states))
                    (list->vector (reverse syntax))
                    (list->vector (reverse word))
                    (list->vector (reverse bracket-roles)))]
      [else
       (define line (car lines))
       (define-values (state* tokens) (tokenize-line state line))
       (define-values (bracket* bracket-vec)
         (bracket-scan-line tokens line bracket))
       (loop (cdr lines) state* bracket*
             (cons state* states)
             (cons bracket* bracket-states)
             (cons (highlight-line tokens line) syntax)
             (cons (word-color-line tokens line) word)
             (cons bracket-vec bracket-roles))])))

(define (color-line-count cache)
  (vector-length (color-state-syntax-roles cache)))

(define (color-syntax-roles cache)
  (vector->list (color-state-syntax-roles cache)))

(define (color-word-roles cache)
  (vector->list (color-state-word-roles cache)))

(define (color-bracket-roles cache)
  (vector->list (color-state-bracket-roles cache)))

;; cache 必须对应旧文本；text 是新文本；edits 是旧→新行区间。
(define (color-edit cache text edits)
  (if (null? edits)
      cache
      (let* ([lines (text-lines text)]
             [n (length lines)]
             [old-states (color-state-lex-out-states cache)]
             [old-bracket-states (color-state-bracket-out-states cache)]
             [old-syntax (color-state-syntax-roles cache)]
             [old-word (color-state-word-roles cache)]
             [old-bracket (color-state-bracket-roles cache)])
        (define-values (states0 bracket-states0 syntax0 word0 bracket0)
          (for/fold ([st old-states]
                     [bst old-bracket-states]
                     [syn old-syntax]
                     [wd old-word]
                     [br old-bracket])
                    ([sp (in-list (edit-spans edits))])
            (define old-start (car sp))
            (define old-end (cadr sp))
            (define new-count (max 0 (- (cadddr sp) (caddr sp))))
            (values (splice-vector-preserve st old-start old-end new-count)
                    (splice-vector-preserve bst old-start old-end new-count)
                    (splice-vector-preserve syn old-start old-end new-count)
                    (splice-vector-preserve wd old-start old-end new-count)
                    (splice-vector-preserve br old-start old-end new-count))))

        ;; 边界：splice 后所有缓存向量都必须和新文本行数一致。
        ;; change 行区间失配（旧缓存 / 多 change / 跨行替换）时不能继续
        ;; vector-set!，直接退回全量，避免越界。
        (if (or (not (= (vector-length states0) n))
                (not (= (vector-length bracket-states0) n))
                (not (= (vector-length syntax0) n))
                (not (= (vector-length word0) n))
                (not (= (vector-length bracket0) n)))
            (color-open text)
            (let ([dirty (edits->dirty-lines edits n)])
              (if (null? dirty)
                  (color-state states0 bracket-states0 syntax0 word0 bracket0)
                  (color-edit-dirty lines n
                                    states0 bracket-states0
                                    syntax0 word0 bracket0
                                    dirty)))))))

;; 从脏行开始带状态重扫；两个出状态都收敛后停止。
(define (color-edit-dirty lines n
                          states0 bracket-states0
                          syntax0 word0 bracket0
                          dirty)
  (define start (car dirty))
  (define last-dirty (car (reverse dirty)))
  (define states* (vector-copy states0))
  (define bracket-states* (vector-copy bracket-states0))
  (define syntax* (vector-copy syntax0))
  (define word* (vector-copy word0))
  (define bracket* (vector-copy bracket0))
  (let loop ([ln start]
             [incoming (if (and (> start 0)
                                (< (sub1 start) (vector-length states*)))
                           (vector-ref states* (sub1 start))
                           empty-lex-state)]
             [incoming-bracket (if (and (> start 0)
                                        (< (sub1 start) (vector-length bracket-states*)))
                                  (vector-ref bracket-states* (sub1 start))
                                  '())])
    (cond
      [(>= ln n)
       (color-state states* bracket-states* syntax* word* bracket*)]
      [else
       (define line (list-ref lines ln))
       (define-values (state* tokens) (tokenize-line incoming line))
       (define-values (bracket-state* bracket-vec)
         (bracket-scan-line tokens line incoming-bracket))
       (define old-state (if (< ln (vector-length states0))
                             (vector-ref states0 ln)
                             #f))
       (define old-bracket-state (if (< ln (vector-length bracket-states0))
                                     (vector-ref bracket-states0 ln)
                                     #f))
       (vector-set! states* ln state*)
       (vector-set! bracket-states* ln bracket-state*)
       (vector-set! syntax* ln (highlight-line tokens line))
       (vector-set! word* ln (word-color-line tokens line))
       (vector-set! bracket* ln bracket-vec)
       (define changed?
         (not (and (equal? state* old-state)
                   (equal? bracket-state* old-bracket-state))))
       (if (and (>= ln last-dirty) (not changed?))
           (color-state states* bracket-states* syntax* word* bracket*)
           (loop (add1 ln) state* bracket-state*))])))
