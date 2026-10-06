#lang racket

;;; lab-rebuild/builtin/status.rkt —— 状态行（before-render 钩子 + slot 内容）。
;;;
;;; 显示**活动编辑视图**（不是焦点所在的面板 / 内部视图）：
;;;   edit vN  行:列  文档名
;;; 焦点在面板 / input 等非编辑视图上时，前缀提示焦点位置（`buffers | edit vN …`）。
;;; 这样分屏里多个 view 同名文档也能从 vN 分辨，且切到面板不会把状态行带跑。
;;;
;;; 装饰内容由 hook 产出 effect（reload）写回 slot 视图，而不是 render 里硬编码。

(require "../kernel/editor-api.rkt"
         "../kernel/effect.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/hooks.rkt"
         "../kernel/registry.rkt"
         "../kernel/panel.rkt"
         "prefix.rkt")

(provide register-status! status-text)

;; 焦点不在活动编辑视图上时，给出焦点所在标签（面板名 / input / state）。
(define (focus-prefix s evid base)
  (define fv (session-focus-vid s))
  (cond
    [(or (not fv) (eqv? fv evid)) base]
    [(eqv? fv (session-status-vid s)) (format " state |~a" base)]
    [(eqv? fv (session-input-vid s)) (format " input |~a" base)]
    [(for/first ([p (in-list (session-panels s))] #:when (eqv? fv (panel-vid p)))
       (format " ~a |~a" (panel-name p) base))]
    [else base]))

(define (status-text ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define vid (session-edit-vid s))
  (define base
    (cond
      [(not vid) " lab-rebuild"]
      [else
       (define did (editor-view-document-id ed vid))
       (format " edit v~a  ~a:~a  ~a"
               vid
               (add1 (editor-view-point-line ed vid))
               (add1 (editor-view-point-column ed vid))
               (editor-document-name ed did))]))
  (define base* (focus-prefix s vid base))
  (define pl (active-prefix-label ctx))
  (if pl (format "~a  [~a-]" base* pl) base*))

(define (status-hook ctx _args)
  (define s (ctx-session ctx))
  (list (e-reload (session-status-vid s) (document-open (status-text ctx)))))

(define (register-status! r)
  (reg-add r (contrib 'hook 'status 0 (make-hook 'before-render status-hook))))
