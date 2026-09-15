#lang racket

(require tui)   ; racket-tui 包（Linux）
(require "../core/view/events.rkt")

;;; input-tui.rkt —— tui 后端的事件解码（参考实现）
;;;
;;; raw 终端事件 → 类型化 ui-event。用户可整体替换此解码（改物理键位等）。
;;; 注意：这里只做「物理输入 → 通用事件」，语义绑定（哪个事件触发哪个命令）
;;; 在 reference/commands.rkt 的命令表里，二者分离。

(provide tui-input-handler)

(define (no-mods) (modifiers #f #f #f #f))

;; build-input 的 mouse 修饰码 = (list ctrl? alt? shift?)
(define (decode-mods mods)
  (modifiers (and (pair? mods) (car mods))
             (and (pair? mods) (cadr mods))
             (and (pair? mods) (caddr mods))
             #f))

(define (tui-input-handler emit)
  (build-input
   #:utf-char  (lambda (s)   (emit (text-event s (no-mods))))
   #:char      (lambda (ch)  (emit (text-event (string (integer->char ch)) (no-mods))))
   #:tab       (lambda ()    (emit (key-event 'tab (no-mods))))
   #:escape    (lambda ()    (emit (key-event 'escape (no-mods))))
   #:up        (lambda ()    (emit (key-event 'up (no-mods))))
   #:down      (lambda ()    (emit (key-event 'down (no-mods))))
   #:left      (lambda ()    (emit (key-event 'left (no-mods))))
   #:right     (lambda ()    (emit (key-event 'right (no-mods))))
   #:backspace (lambda ()    (emit (key-event 'backspace (no-mods))))
   #:enter     (lambda ()    (emit (key-event 'enter (no-mods))))
   #:delete    (lambda ()    (emit (key-event 'delete (no-mods))))
   #:home      (lambda ()    (emit (key-event 'home (no-mods))))
   #:end       (lambda ()    (emit (key-event 'end (no-mods))))
   #:pageup    (lambda ()    (emit (key-event 'pageup (no-mods))))
   #:pagedown  (lambda ()    (emit (key-event 'pagedown (no-mods))))
   #:ctrl      (lambda (ch)  (emit (key-event ch (modifiers #t #f #f #f))))
   #:resize    (lambda (r c) (emit (resize-event (max 1 (sub1 r)) c)))
   #:mouse-press
   (lambda (btn x y mods)
     (emit (mouse-press-event btn (sub1 x) (sub1 y) (decode-mods mods))))
   #:mouse-scroll
   (lambda (dir x y mods)
     (emit (mouse-wheel-event dir (sub1 x) (sub1 y) (decode-mods mods))))
   #:paste     (lambda (data) (emit (text-event (bytes->string/utf-8 data) (no-mods))))
   #:any       (lambda (t d m) (void))))
