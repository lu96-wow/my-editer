#lang racket

;;; edit4/runtime.rkt —— 事件循环 + 后端协议（唯一可变处）
;;;
;;; 每帧：算 frame（缓存）→ 渲染 → draw → 读事件 → dispatch → 解释 effect。
;;; 只有本模块持有可变状态：几何缓存、上一帧屏幕、后端资源。

(provide (struct-out backend) run)

(require "core/world.rkt" "core/event.rkt" "core/effect.rkt"
         "core/command.rkt" "core/dispatch.rkt"
         "layout.rkt" "content/content.rkt" "content/engine.rkt" "view/render.rkt")

(struct backend (size read-event draw! close) #:transparent)

(define (perform-effect! b e)
  (cond
    [(quit-effect? e) ((backend-close b))]
    [(log-effect? e) (eprintf "~a\n" (log-effect-msg e))]
    [(save-file? e) (call-with-output-file (save-file-path e) #:exists 'truncate/replace
                      (lambda (o) (display (save-file-text e) o)))]
    [else (void)]))

(define (run b reg scopes km world)
  (define cache (box empty-layout-cache))
  (let loop ([w world] [old #f] [old-size #f])
    (define size ((backend-size b)))
    (define-values (cache* fr) (ensure-layout (unbox cache) (world-layout w) (world-floats w) size))
    (set-box! cache cache*)
    (define c (world-content w))
    (define id->vid (and c (lambda (id) (content-vid-of c id))))
    (define ed (and c (content-ed c)))
    (define active (and id->vid (id->vid (world-focus w))))
    (define-values (screen rends sels)
      (if (and ed id->vid)
          (render-frame ed fr id->vid active (car size) (cdr size)
                        (and (equal? size old-size) old))
          (values #f '() '())))
    ((backend-draw! b) (append rends sels))
    (define ev ((backend-read-event b)))
    (cond
      [(resize-event? ev)
       (define area (rect 0 0 (resize-event-w ev) (resize-event-h ev)))
       (loop (world-set-layout w (settle (world-layout w) area)) screen old-size)]
      [else
       (define-values (w* effs) (dispatch reg scopes km (ctx ev size fr) w))
       (for ([e (in-list effs)]) (perform-effect! b e))
       (if (for/or ([e (in-list effs)]) (quit-effect? e))
           w*
           (loop w* screen size))])))
