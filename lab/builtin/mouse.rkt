#lang racket

;;; lab-rebuild/builtin/mouse.rkt —— 鼠标命令（功能包）。
;;;
;;; 鼠标事件走同一条 resolve：mouse 绑定 → 命令 → effect。
;;; 命中哪个窗格由 render 的 hit-pane 提供；命令不 require app / backend。

(require "../kernel/editor-api.rkt"
         "../kernel/binding.rkt"
         "../kernel/effect.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../kernel/layout.rkt")

(provide register-mouse!)

(define (cmd-mouse-press ctx ev)
  (define r (hit-pane ctx (mouse-col ev) (mouse-row ev)))
  (cond
    [(not r) '()]
    [else
     (define vid (rectangle-view-id r))
     (list (e-focus vid)
           (e-pointer vid
                      (- (mouse-row ev) (rectangle-y r))
                      (- (mouse-col ev) (rectangle-x r))))]))

(define (cmd-mouse-scroll ctx ev delta)
  (define r (hit-pane ctx (mouse-col ev) (mouse-row ev)))
  (if r (list (e-scroll (rectangle-view-id r) delta)) '()))

;; effect 处理器（feature 自带）：鼠标定位 / 滚动。
(define (apply-pointer ctx vid row col)
  (define ed (session-editor (ctx-session ctx)))
  (define-values (line c) (editor-view-screen-position->point ed vid row col))
  (when line (editor-view-set-point! ed vid (point line c)))
  ctx)

(define (apply-scroll ctx vid delta)
  (editor-view-scroll! (session-editor (ctx-session ctx)) vid delta)
  ctx)

(define (register-mouse! r)
  (for/fold ([r r]) ([c (in-list (list (contrib 'command 'mouse-press 0 cmd-mouse-press)
                                       (contrib 'command 'mouse-scroll 0 cmd-mouse-scroll)
                                       (contrib 'effect 'pointer 0 apply-pointer)
                                       (contrib 'effect 'scroll 0 apply-scroll)))])
    (reg-add r c)))
