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

(require "../../core/api.rkt"
         "../engine/api.rkt"
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

;;; ════════════════ 其他操作（暂时不带 hook） ════════════════

(define (surface-paste! ed state vid bytes)
  (raw-paste! (editor-engine ed) vid bytes)
  (values state '()))

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
  (raw-undo! (editor-engine ed) vid)
  (values state '()))

(define (surface-redo! ed state vid)
  (raw-redo! (editor-engine ed) vid)
  (values state '()))

(define (surface-kill-line! ed state vid)
  (raw-kill-line! (editor-engine ed) vid)
  (values state '()))

(define (surface-ensure! ed state vid)
  (raw-ensure! (editor-engine ed) vid)
  (values state '()))
