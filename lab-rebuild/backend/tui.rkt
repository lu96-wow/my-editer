#lang racket

;;; lab-rebuild/backend/tui.rkt —— racket-tui 后端（增量 patch + face/overlay 配色）。

(require (prefix-in tui: tui)
         "../kernel/editor-api.rkt"
         "../kernel/session.rkt"
         "../kernel/theme.rkt"
         "../kernel/runtime.rkt"
         "../kernel/render.rkt"
         "../kernel/pipeline.rkt"
         "../config/theme.rkt"
         "../app/app.rkt")

(provide app-run app-draw!)

(define (rgb-fg rgb) (if rgb (apply tui:format-rgb-fg-base rgb) #""))
(define (rgb-bg rgb) (if rgb (apply tui:format-rgb-bg-base rgb) #""))

;; attr = face 或 (overlay . face)：cursor → 反色；否则 overlay 颜色覆盖 face 分量。
(define (style-bytes attr)
  (define ov (and (pair? attr) (car attr)))
  (define face (if (pair? attr) (cdr attr) attr))
  (cond
    [(eq? ov 'cursor) tui:format-reverse]
    [else
     (define-values (fg bg) (theme-face-colors (current-theme) face))
     (define-values (ofg obg) (theme-overlay-colors (current-theme) ov))
     (bytes-append (rgb-fg (or ofg fg)) (rgb-bg (or obg bg)))]))

(define prev (box #f))

(define (app-draw! ctx)
  (define old (unbox prev))
  (define-values (ctx1 new render selection) (app-render-patch ctx old))
  (define fresh? (or (not old)
                     (not (= (screen-width old) (screen-width new)))
                     (not (= (screen-height old) (screen-height new)))))
  (set-box! prev new)
  (define parts '())
  (define (add! b) (set! parts (cons b parts)))
  (add! tui:format-cursor-hide)
  (when fresh? (add! tui:format-screen-clear))
  (for ([p (in-list (append render selection))])
    (add! (bytes-append
           (tui:format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
           (style-bytes (piece-attr p))
           (tui:format-content (piece-text p))
           tui:format-reset)))
  (add! tui:format-cursor-show)
  (tui:put-bytes (apply bytes-append (reverse parts)))
  (tui:flush!)
  ctx1)

(define (app-run root [open-path #f])
  (tui:with-tui
   (lambda ()
     (define-values (rows cols) (tui:get-window-size))
     (define ctx0 (app-init root (or cols 80) (or rows 24) #:background? #t))
     (define c0 (if open-path (app-open ctx0 open-path) ctx0))
     (define ctxbox (box c0))
     (define (tick!)
       (set-box! ctxbox (run-notify (unbox ctxbox) 'job-tick '()))
       (set-box! ctxbox (app-draw! (unbox ctxbox))))
     (for ([src (in-list (runtime-sources (ctx-runtime (unbox ctxbox))))])
       (define s (src))
       (when s (tui:on-source s (lambda (_) (tick!)))))
     (dynamic-wind
       void
       (lambda ()
         (set-box! ctxbox (app-draw! (unbox ctxbox)))
         (let loop ()
           (define ev (tui:read-event))
           (set-box! ctxbox (step (unbox ctxbox) ev))
           (unless (session-quit? (ctx-session (unbox ctxbox)))
             (set-box! ctxbox (app-draw! (unbox ctxbox)))
             (loop))))
       void))))
