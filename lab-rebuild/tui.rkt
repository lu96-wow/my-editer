#lang racket

(require (prefix-in tui: tui)
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "app.rkt"
         "input.rkt")

;;; lab-rebuild/tui.rkt —— racket-tui 后端
;;;
;;;   racket lab-rebuild/main.rkt [根目录]
;;;
;;; 事件已经是 racket-tui 的规范事件，直接喂 app-handle-input。

(provide app-draw! app-run)

;;; ================= face → ANSI =================

(define (rgb-fg rgb) (if rgb (apply tui:format-rgb-fg-base rgb) #""))
(define (rgb-bg rgb) (if rgb (apply tui:format-rgb-bg-base rgb) #""))

(define (face-colors face)
  (case face
    [(line-number) (values '(90 96 110) #f)]
    [(tree-dir)    (values '(120 180 240) #f)]
    [(tree-file)   (values '(200 200 200) #f)]
    [(tree-link)   (values '(120 200 200) #f)]
    [(tree-hidden) (values '(120 120 130) #f)]
    [(tree-open)   (values '(120 210 130) #f)]
    [(input)       (values '(20 20 20) '(230 200 90))]
    [(state status) (values '(225 225 225) '(40 44 52))]
    [(buf-current) (values '(120 210 130) #f)]
    [(buf-file)    (values '(200 200 200) #f)]
    [(buf-untitled) (values '(170 170 170) #f)]
    [(buf-view)    (values '(140 160 190) #f)]
    [else          (values '(205 205 205) #f)]))

(define (overlay-colors ov)
  (case ov
    [(selection) (values #f '(58 74 128))]
    [else        (values #f #f)]))

(define (style-bytes attr)
  (define ov (and (pair? attr) (car attr)))
  (define face (if (pair? attr) (cdr attr) attr))
  (cond
    [(eq? ov 'cursor) tui:format-reverse]
    [else
     (define-values (fg bg) (face-colors face))
     (define-values (ofg obg) (overlay-colors ov))
     (bytes-append (rgb-fg (or ofg fg)) (rgb-bg (or obg bg)))]))

;;; ================= 渲染一帧 =================

(define (app-draw! a)
  (define ed (app-editor a))
  (define w (app-width a))
  (define h (app-height a))
  (define panes (app-prepare! a))           ; 刷新 state 槽位 + 取本帧窗格
  (define prev (app-prev a))
  (define fresh? (or (not prev)
                     (not (= (screen-width prev) w))
                     (not (= (screen-height prev) h))))
  (editor-set-layout! ed panes)
  (define-values (new render selection)
    (editor-render-layout-patch ed (and (not fresh?) prev) panes (app-focus a) w h))
  (set-app-prev! a new)
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
  (tui:flush!))

;;; ================= 主循环 =================

(define (app-run root)
  (tui:with-tui
   (lambda ()
     (define-values (rows cols) (tui:get-window-size))
     (define a (app-init root (or cols 80) (or rows 24)))
     (app-draw! a)
     (let loop ([a a])
       (define ev (tui:read-event))
       (app-handle-input a ev)
       (unless (app-quit? a)
         (app-draw! a)
         (loop a))))))
