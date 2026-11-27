#lang racket

;;; edit-tui/lang/c/color/color.rkt —— C 增量语法高亮（纯）
;;;
;;; 缓存：
;;;   lex-out-states : 每行行尾词法状态（块注释 / 字符串 / 字符）
;;;   syntax-roles   : 每行 role 向量
;;;
;;; changes 只重扫受影响的脏行；块注释 / 字符串状态变化时向后推进到收敛。

(require racket/list
         "../../shared/edit.rkt"
         "../base/lex.rkt"
         "highlight.rkt")

(provide (struct-out c-color-state)
         c-color-open
         c-color-open-lines
         c-color-edit
         c-color-edit*
         c-color-edit*/lines
         c-color-syntax-roles
         c-color-line-count)

(struct c-color-state
  (lex-out-states ; vector line -> 行尾 c-lex-state
   syntax-roles)  ; vector line -> (vector role|#f)
  #:transparent)

(define (c-color-open text)
  (c-color-open-lines (c-text-lines text)))

(define (c-color-open-lines lines)
  (let loop ([lines lines]
             [state c-empty-lex-state]
             [states '()]
             [syntax '()])
    (cond
      [(null? lines)
       (c-color-state (list->vector (reverse states))
                      (list->vector (reverse syntax)))]
      [else
       (define line (car lines))
       (define-values (state* tokens) (c-tokenize-line state line))
       (loop (cdr lines) state*
             (cons state* states)
             (cons (c-highlight-line tokens line) syntax))])))

(define (c-color-line-count cache)
  (vector-length (c-color-state-syntax-roles cache)))

(define (c-color-syntax-roles cache)
  (vector->list (c-color-state-syntax-roles cache)))

(define (c-color-edit cache text edits)
  (let-values ([(state _dirty) (c-color-edit* cache text edits)])
    state))

;; → (values c-color-state' dirty-lines)
;; dirty-lines : (listof line-no) | 'all
(define (c-color-edit* cache text edits)
  (c-color-edit*/lines cache (c-text-lines text) edits))

(define (c-color-edit*/lines cache lines edits)
  (if (null? edits)
      (values cache '())
      (let* ([linev (if (vector? lines) lines (list->vector lines))]
             [n (vector-length linev)]
             [old-states (c-color-state-lex-out-states cache)]
             [old-syntax (c-color-state-syntax-roles cache)]
             [states0
              (for/fold ([v old-states])
                        ([sp (in-list (edit-spans edits))])
                (splice-vector-preserve v (car sp) (cadr sp)
                                        (max 0 (- (cadddr sp) (caddr sp))))) ]
             [syntax0
              (for/fold ([v old-syntax])
                        ([sp (in-list (edit-spans edits))])
                (splice-vector-preserve v (car sp) (cadr sp)
                                        (max 0 (- (cadddr sp) (caddr sp)))))])
        (if (or (not (= (vector-length states0) n))
                (not (= (vector-length syntax0) n)))
            (values (c-color-open-lines (if (vector? lines) (vector->list lines) lines)) 'all)
            (let ([dirty (edits->dirty-lines edits n)])
              (if (null? dirty)
                  (values (c-color-state states0 syntax0) '())
                  (c-color-edit-dirty linev n states0 syntax0 dirty)))))))

(define (c-color-edit-dirty lines n states* syntax* dirty)
  (define start (car dirty))
  (define last-dirty (last dirty))
  (let loop ([ln start]
             [incoming (if (and (> start 0)
                                (< (sub1 start) (vector-length states*)))
                           (vector-ref states* (sub1 start))
                           c-empty-lex-state)]
             [touched '()])
    (cond
      [(>= ln n)
       (values (c-color-state states* syntax*) (reverse touched))]
      [else
       (define line (vector-ref lines ln))
       (define-values (state* tokens) (c-tokenize-line incoming line))
       ;; splice 出来的向量已是最新副本，直接改写；改写前取旧值判断收敛。
       (define old-state (vector-ref states* ln))
       (define changed? (not (equal? state* old-state)))
       (vector-set! states* ln state*)
       (vector-set! syntax* ln (c-highlight-line tokens line))
       (if (and (>= ln last-dirty) (not changed?))
           (values (c-color-state states* syntax*) (reverse (cons ln touched)))
           (loop (add1 ln) state* (cons ln touched)))])))
