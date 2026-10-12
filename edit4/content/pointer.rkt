#lang racket

;;; edit4/content/pointer.rkt —— 指针命令的内容扩展：点击放置光标
;;;
;;; 覆盖 core 的 pointer-press：先跑 base（命中 → 设焦点 / 起拖拽），
;;; 若命中的是窗格或浮窗正文，再把屏幕坐标换算成该文档的点并置光标。
;;; 「屏幕坐标 → 文档点」是内容域知识（引擎负责滚动/左边距），所以扩展在这里。
;;;
;;; 键盘 / 鼠标统一：这是「点击不放光标」这个已知限制的解法。

(provide content-pointer-commands)

(require "../core/world.rkt" "../core/event.rkt" "../core/command.rkt" "../core/pointer.rkt"
         "../layout.rkt"
         "model.rkt" "adapter.rkt")

(define (place-cursor w id r x y)
  (define c (world-content w))
  (define vid (and c (content-vid-of c id)))
  (cond
    [(not (and c vid r)) (void)]
    [else
     (define p (screen->point (content-ed c) vid
                              (max 0 (- y (rect-y r)))
                              (max 0 (- x (rect-x r)))))
     (when p (set-point! (content-ed c) vid (car p) (cdr p)))]))

(define (h-pointer-press ctx w args)
  (define r (pointer-press ctx w args))
  (cond
    [(not r) #f]
    [else
     (define fr (ctx-frame ctx))
     (define ev (ctx-event ctx))
     (cond
       [(not fr) r]
       [else
        (define x (cursor-event-x ev))
        (define y (cursor-event-y ev))
        (define t (hit-frame fr x y))
        (cond
          [(pane-target? t)
           (place-cursor (car r) (pane-target-id t)
                         (hash-ref (geometry-rects (frame-tiled fr)) (pane-target-id t) #f) x y)]
          ;; 浮窗正文（非角）→ 也放光标；角落留给缩放拖拽。
          [(and (float-target? t) (eq? 'move (float-target-action t)))
           (place-cursor (car r) (float-target-id t)
                         (frame-float-content-rect fr (float-target-id t)) x y)])
        r])]))

(define content-pointer-commands
  (make-command-registry (list (cons 'pointer-press h-pointer-press))))
