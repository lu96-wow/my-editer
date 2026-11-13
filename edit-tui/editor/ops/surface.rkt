#lang racket

;;; edit-tui/editor/ops/surface.rkt —— 操作面（带扩展点）
;;;
;;; 只有这里负责：
;;;   · 构造 edit-context
;;;   · 跑 before hooks
;;;   · 调用 raw 操作
;;;   · 跑 after hooks
;;;   · 把 hook 返回的 plugin-state 写回 editor-state
;;;
;;; 插件不直接调用 raw.rkt；它们注册 hook，或者通过 editor/api.rkt 调操作面。

(require (only-in racket/list take drop)
         (only-in racket/string string-split string-join)
         "../../core/api.rkt"
         "../engine/read.rkt"
         "../context.rkt"
         "../state.rkt"
         "../hooks.rkt"
         "../action.rkt"
         "raw.rkt")

(provide surface-insert!
         surface-delete!
         surface-paste!
         surface-move!
         surface-set-point!
         surface-select!
         surface-scroll!
         surface-replace-range!
         surface-replace-lines!
         surface-undo!
         surface-redo!
         surface-kill-line!
         surface-ensure!)

;;; ════════════════ 内部：光标调整 ════════════════

(define (move-caret! engine vid delta)
  (define dir (if (< delta 0) 'left 'right))
  (for ([_ (in-range (abs delta))])
    (raw-move! engine vid dir #f)))

(define (current-point engine vid)
  (point (or (engine-view-point-line engine vid) 0)
         (or (engine-view-point-column engine vid) 0)))

;; 一次用户操作 = 一个 core undo step。
;; 自动配对删除会发两次 raw 操作，必须合并成一个撤销步。
(define (with-view-undo-step engine vid thunk)
  (define v (engine-view-object engine vid))
  (if v
      (buffer-with-undo-step (view-buffer v) thunk)
      (thunk)))

(define (run-before registry operation ctx state)
  (run-before-hooks registry operation ctx state))

(define (run-after registry operation ctx state)
  (run-after-hooks registry operation ctx state))

;; 一次操作产生的 change 批次 -> 'changes 扩展点。
(define (run-change-hooks ed state vid base-version changes)
  (define engine (editor-engine ed))
  (define did (engine-view-doc-id engine vid))
  (cond
    [(or (not did) (not (pair? changes)))
     (values state '())]
    [else
     (define version (engine-doc-version engine did))
     (define ctx (make-change-context ed engine state did base-version version changes))
     (define-values (_ctx state* actions)
       (run-after (editor-registry ed) 'changes ctx state))
     (values state* actions)]))

;;; ════════════════ insert ════════════════

;; text : string
;; → (values state' actions)
(define (surface-insert! ed state vid text)
  (define engine (editor-engine ed))
  (define ctx0
    (make-edit-context ed engine state vid 'insert
                       #:point (current-point engine vid)
                       #:text text))
  (define-values (ctx1 state1 actions1 allow?)
    (run-before (editor-registry ed) 'insert ctx0 state))
  (cond
    [(not allow?)
     (values state1 actions1)]
    [else
     (define text* (or (edit-context-text ctx1) ""))
     (define did0 (engine-view-doc-id engine vid))
     (define base-version (and did0 (engine-doc-version engine did0)))
     (define changes
       (with-view-undo-step
        engine vid
        (λ ()
          (define ch
            (if (zero? (string-length text*))
                '()
                (raw-insert! engine vid text*)))
          ;; before transform 可以要求提交后移动光标（自动配对：插 "()" 后左移一格）。
          (move-caret! engine vid (edit-context-caret-delta ctx1))
          ch)))
     (define ctx2
       (struct-copy edit-context ctx1
                    [point (current-point engine vid)]
                    [result changes]))
     (define-values (_ctx3 state3 actions3)
       (run-after (editor-registry ed) 'insert ctx2 state1))
     (define-values (state4 actions4)
       (run-change-hooks ed state3 vid base-version changes))
     (values state4 (append actions1 actions3 actions4))]))

;;; ════════════════ delete ════════════════

;; kind : 'backspace | 'delete
;; count 由 before hook 修改（自动配对：空括号中间删一对）。
(define (surface-delete! ed state vid kind)
  (define engine (editor-engine ed))
  (define ctx0
    (make-edit-context ed engine state vid kind
                       #:point (current-point engine vid)
                       #:count 1))
  (define-values (ctx1 state1 actions1 allow?)
    (run-before (editor-registry ed) 'delete ctx0 state))
  (cond
    [(not allow?)
     (values state1 actions1)]
    [else
     (define did0 (engine-view-doc-id engine vid))
     (define base-version (and did0 (engine-doc-version engine did0)))
     (define n (max 0 (edit-context-count ctx1)))
     (define plan
       (or (edit-context-delete-plan ctx1)
           (for/list ([_ (in-range n)]) kind)))
     (define changes
       (with-view-undo-step
        engine vid
        (λ ()
          (append*
           (for/list ([k (in-list plan)])
             (define c
               (case k
                 [(backspace) (raw-backspace! engine vid)]
                 [(delete) (raw-delete! engine vid)]
                 [else (error 'surface-delete! "未知 delete kind：~a" k)]))
             (if (pair? c) c '()))))))
     (define ctx2
       (struct-copy edit-context ctx1
                    [point (current-point engine vid)]
                    [result changes]))
     (define-values (_ctx3 state3 actions3)
       (run-after (editor-registry ed) 'delete ctx2 state1))
     (define-values (state4 actions4)
       (run-change-hooks ed state3 vid base-version changes))
     (values state4 (append actions1 actions3 actions4))]))

;;; ════════════════ 其他文本操作（不跑 edit hook，但统一进 changes 流） ════════════════

(define (base-version-for-view engine vid)
  (define did (engine-view-doc-id engine vid))
  (and did (engine-doc-version engine did)))

(define (run-text-changes ed state vid base-version changes)
  (run-change-hooks ed state vid base-version changes))

(define (surface-paste! ed state vid bytes)
  (define engine (editor-engine ed))
  (define base-version (base-version-for-view engine vid))
  (define changes (raw-paste! engine vid bytes))
  (run-text-changes ed state vid base-version changes))

(define (surface-move! ed state vid dir [extend? #f])
  (raw-move! (editor-engine ed) vid dir extend?)
  (values state '()))

(define (surface-set-point! ed state vid line col [extend? #f])
  (raw-set-point! (editor-engine ed) vid line col extend?)
  (values state '()))

(define (surface-select! ed state vid sels)
  (raw-set-selections! (editor-engine ed) vid sels)
  (values state '()))

(define (surface-scroll! ed state vid which)
  (raw-scroll! (editor-engine ed) vid which)
  (values state '()))

(define (surface-undo! ed state vid)
  (define engine (editor-engine ed))
  (define base-version (base-version-for-view engine vid))
  (define changes (raw-undo! engine vid))
  (run-text-changes ed state vid base-version changes))

(define (surface-redo! ed state vid)
  (define engine (editor-engine ed))
  (define base-version (base-version-for-view engine vid))
  (define changes (raw-redo! engine vid))
  (run-text-changes ed state vid base-version changes))

(define (surface-kill-line! ed state vid)
  (define engine (editor-engine ed))
  (define base-version (base-version-for-view engine vid))
  (define changes (raw-kill-line! engine vid))
  (run-text-changes ed state vid base-version changes))

(define (surface-ensure! ed state vid)
  (raw-ensure! (editor-engine ed) vid)
  (values state '()))


;;; ════════════════ 程序化替换（只写 user doc） ════════════════

;; 程序化替换不跑 insert/delete 的 before hooks（pair/indent 不应改写
;; 翻译器写入的文本），但必须进入 'changes 流。
(define (surface-replace-range! ed state vid r text)
  (define engine (editor-engine ed))
  (cond
    [(not (eq? (engine-view-kind engine vid) 'user))
     (values (state-with-flash state "replace-range: view is not a user document")
             '())]
    [else
     (define base-version (base-version-for-view engine vid))
     (define changes
       (with-view-undo-step
        engine vid
        (lambda () (raw-replace-range! engine vid r text))))
     (run-text-changes ed state vid base-version changes)]))

;; start-line inclusive / end-line exclusive；lines 不含换行。
;; 旧文本和构造出的新文本做字符级 diff，再发最小区间替换。
(define (surface-replace-lines! ed state vid start-line end-line lines)
  (define engine (editor-engine ed))
  (cond
    [(not (eq? (engine-view-kind engine vid) 'user))
     (values (state-with-flash state "replace-lines: view is not a user document")
             '())]
    [else
     (define old-text (engine-view-text engine vid))
     (define old-lines (and old-text (string-split old-text "\n" #:trim? #f)))
     (define n (and old-lines (length old-lines)))
     (cond
       [(or (not n)
            (not (exact-nonnegative-integer? start-line))
            (not (exact-nonnegative-integer? end-line))
            (> start-line end-line)
            (> end-line n))
        (values (state-with-flash state "replace-lines: bad line range")
                '())]
       [else
        (define new-lines
          (append (take old-lines start-line)
                  lines
                  (drop old-lines end-line)))
        (surface-replace-text! ed state vid (string-join new-lines "\n"))])]))

(define (common-prefix-length a b)
  (define n (min (string-length a) (string-length b)))
  (let loop ([i 0])
    (cond
      [(>= i n) i]
      [(char=? (string-ref a i) (string-ref b i)) (loop (add1 i))]
      [else i])))

(define (common-suffix-length a b limit)
  (let loop ([i 0])
    (cond
      [(>= i limit) i]
      [(char=? (string-ref a (- (string-length a) 1 i))
               (string-ref b (- (string-length b) 1 i)))
       (loop (add1 i))]
      [else i])))

(define (offset->point text offset)
  (define n (min (max 0 offset) (string-length text)))
  (let loop ([i 0] [line 0] [col 0])
    (cond
      [(>= i n) (point line col)]
      [(char=? (string-ref text i) #\newline)
       (loop (add1 i) (add1 line) 0)]
      [else (loop (add1 i) line (add1 col))])))

(define (surface-replace-text! ed state vid new-text)
  (define engine (editor-engine ed))
  (define old-text (engine-view-text engine vid))
  (cond
    [(not old-text)
     (values (state-with-flash state "replace-text: no view text") '())]
    [else
     (define cp (common-prefix-length old-text new-text))
     (define max-suffix (- (min (string-length old-text)
                                (string-length new-text))
                           cp))
     (define cs (common-suffix-length old-text new-text max-suffix))
     (define old-end (- (string-length old-text) cs))
     (define new-end (- (string-length new-text) cs))
     (cond
       [(and (= cp old-end) (= cp new-end))
        (values state '())]
       [else
        (define r (range (offset->point old-text cp)
                         (offset->point old-text old-end)))
        (define inserted (substring new-text cp new-end))
        (surface-replace-range! ed state vid r inserted)])]))
