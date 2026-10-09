#lang racket

;;; lab-re-rebuild/backend/tui.rkt —— racket-tui 后端（增量 patch + 软件光标）。
;;;
;;; ⚠ 不能整屏打印 screen->string：raw 模式下光标定位靠 piece 的 (row,col)，
;;;   而不是裸 \n；且硬件光标要隐藏、光标用反色格软件绘制（否则光标停在末行=状态栏）。

(require (prefix-in tui: tui)
         "../kernel/editor-api.rkt"
         "../kernel/session.rkt"
         "../kernel/theme.rkt"
         "../kernel/runtime.rkt"
         "../kernel/pipeline.rkt"
         "../kernel/render.rkt"
         "../config/theme.rkt"
         "../app/app.rkt")

(provide app-run)

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
  (tui:put-bytes (apply bytes-append (reverse parts)))
  (tui:flush!)
  ctx1)

(define (app-run)
  (tui:with-tui
   (lambda ()
     (define-values (rows cols) (tui:get-window-size))
     (define ctx0 (app-init (current-directory) (or cols 80) (or rows 24)))
     (let loop ([ctx (app-draw! ctx0)])
       (define ev (tui:read-event))
       (define ctx* (step ctx ev))
       (unless (session-quit? (ctx-session ctx*))
         (loop (app-draw! ctx*)))))))
