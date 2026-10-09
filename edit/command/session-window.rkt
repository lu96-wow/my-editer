#lang racket

;;; edit/command/session-window.rkt —— 状态窗口 + 输入行 + 命令处理链 + 焦点 + refresh
;;;
;;; 状态窗口（panel）：一块停靠视图 + 内容生成 + 自己的键表；同组（同位置）互斥。
;;; 输入行（prompt）：label 只读前缀 + 可编辑，Enter 提交 / Esc 取消。

(require "session-value.rkt"
         "session-core.rkt"
         "../../core/editor.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/point.rkt"
         "../core/focus.rkt")

(provide
 session-add-panel session-panel session-panel-vid session-vid-keys
 session-panel-dids session-dock-vid? session-panel-swap
 session-add-handler
 session-set-focus
 session-refresh
 session-prompt-open session-prompt-submit session-prompt-cancel)

;;; ---------- 状态窗口 ----------

(define (session-panel s vid)
  (for/first ([p (in-list (session-panels s))] #:when (eqv? vid (panel-vid p))) p))
(define (session-panel-vid s id)
  (for/first ([p (in-list (session-panels s))] #:when (eq? id (panel-id p))) (panel-vid p)))
(define (session-vid-keys s vid)
  (define p (session-panel s vid))
  (and p (panel-keys p)))
(define (session-dock-vid? s vid)
  (and vid (and (session-panel s vid) #t)))
(define (session-add-panel s p)
  (struct-copy session s [panels (append (session-panels s) (list p))]))
(define (session-panel-dids s)
  (for/list ([p (in-list (session-panels s))])
    (editor-view-document-id (session-ed s) (panel-vid p))))

;; 同组（同位置）窗口互换：Tab。
(define (session-panel-swap s)
  (define cur (session-focus-vid s))
  (define curp (and cur (session-panel s cur)))
  (define group
    (cond [(and curp (panel-group curp)) (panel-group curp)]
          [else (for/first ([p (in-list (session-panels s))] #:when (panel-group p))
                  (panel-group p))]))
  (cond
    [(not group) s]
    [else
     (define members (for/list ([p (in-list (session-panels s))]
                               #:when (eq? group (panel-group p))) p))
     (define idx (for/first ([p (in-list members)] [i (in-naturals)]
                             #:when (eqv? (panel-vid p) cur)) i))
     (define chosen (list-ref members (if idx (modulo (add1 idx) (length members)) 0)))
     (define cvid (panel-vid chosen))
     (define s1 (for/fold ([s s]) ([p (in-list members)])
                  (session-set-visible s (panel-vid p) (eqv? (panel-vid p) cvid))))
     (session-set-focus s1 (focus-set (session-focus s1) cvid))]))

;;; ---------- 命令处理链 ----------

(define (session-add-handler s h)
  (struct-copy session s [handlers (cons h (session-handlers s))]))

;;; ---------- 焦点 ----------

(define (session-set-focus s f)
  (define vid (focus-target f))
  (define edit (if (and vid (not (session-dock-vid? s vid))) vid (session-edit-vid s)))
  (struct-copy session s [focus f] [edit-vid edit]))

;;; ---------- 刷新状态窗口 ----------

(define (session-refresh s)
  (for ([p (in-list (session-panels s))])
    (define f (panel-refresh p))
    (when f
      (define doc (f s))
      (when doc (editor-view-assign! (session-ed s) (panel-vid p) doc))))
  s)

;;; ---------- 输入行 ----------

(define (prompt-document label)
  (define doc (document-open label))
  (when (positive? (string-length label))
    (document-readonly-fill-batch doc (list (list 0 0 0 (string-length label) #t))))
  doc)

(define (session-prompt-open s vid label on-submit)
  (define ed (session-ed s))
  (editor-view-assign! ed vid (prompt-document label))
  (editor-view-set-point! ed vid (point 0 (string-length label)))
  (define s1 (session-set-visible s vid #t))
  (define s2 (session-set-focus s1 (focus-push (session-focus s1) vid)))
  (struct-copy session s2 [prompt (prompt vid label on-submit)]))

(define (session-prompt-close s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define s1 (session-set-visible s (prompt-vid p) #f))
     (define s2 (session-set-focus s1 (focus-restore (session-focus s1))))
     (struct-copy session s2 [prompt #f])]))

;; Enter：取 label 之后的文本 → 关输入行 → 回调。
(define (session-prompt-submit s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define full (editor-view-string (session-ed s) (prompt-vid p)))
     (define label (prompt-label p))
     (define text (substring full (min (string-length label) (string-length full))
                             (string-length full)))
     ((prompt-on-submit p) (session-prompt-close s) text)]))

(define (session-prompt-cancel s) (session-prompt-close s))
