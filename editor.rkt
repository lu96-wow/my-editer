#lang racket

(require "events.rkt" "cursor.rkt" "buffer.rkt" "window.rkt"
         "plugin.rkt" "view.rkt" rackunit)

;;; editor.rkt —— 应用层：编辑器状态 + 命令 + 事件处理
;;;
;;; 与后端无关：只消费 ui-event，产出 screen（经 paint）。
;;; 命令 = (-> editor editor)，内部走 buffer-* + 插件组合。

(provide
 (struct-out editor)
 make-editor
 editor-handle
 editor-done?)

(struct editor (buffer window plugins done?) #:transparent)

(define (make-editor b0 [plugins '()] [height 24] [width 80])
  (define b* (run-plugins-init b0 plugins))   ; 挂载时全量扫一遍插件
  (editor b* (window-open b* height width) plugins #f))

;; 应用一个 buffer 编辑原语 + 跑插件，并把 window.buffer 同步到新值。
(define (editor-edit e f)
  (define b (editor-buffer e))
  (define-values (b1 desc) (f b))
  (define b* (run-plugins b1 (editor-plugins e)))
  (values (struct-copy editor e
            [buffer b*]
            [window (window-set-buffer (editor-window e) b*)])
          desc))

;; 只改 window（滚动 / 尺寸等）。
(define (editor-window* e f)
  (values (struct-copy editor e [window (f (editor-window e))]) #f))

(define (handle-raw e ev)
  (match (ui-event-kind ev)
    ['insert-string
     (editor-edit e (lambda (b) (buffer-insert-text b (car (ui-event-data ev)))))]
    ['move-up    (editor-edit e (lambda (_b) (window-visual-move (editor-window e) -1)))]
    ['move-down  (editor-edit e (lambda (_b) (window-visual-move (editor-window e) +1)))]
    ['move-left  (editor-edit e buffer-left)]
    ['move-right (editor-edit e buffer-right)]
    ['backspace  (editor-edit e buffer-backspace)]
    ['delete     (editor-edit e buffer-delete)]
    ['newline    (editor-edit e buffer-newline)]
    ['home       (editor-edit e buffer-home)]
    ['end        (editor-edit e buffer-end)]
    ['pageup     (editor-window* e (lambda (w) (window-scroll-visual w (- (window-height w) 1))))]
    ['pagedown   (editor-window* e (lambda (w) (window-scroll-visual w (- (window-height w) 1))))]
    ['ctrl-char  (handle-ctrl e (car (ui-event-data ev)))]
    ['resize     (match-define (list rows cols) (ui-event-data ev))
                 (editor-window* e (lambda (w) (window-set-size w rows cols)))]
    ['mouse-press  (handle-mouse-press e (ui-event-data ev))]
    ['mouse-scroll (handle-mouse-scroll e (ui-event-data ev))]
    ['quit       (values (struct-copy editor e [done? #t]) #f)]
    [_ (values e #f)]))

;; 这些事件会移动光标 → 之后让窗口跟随（滚动/限位）
(define ensure-visible-kinds
  '(insert-string move-up move-down move-left move-right backspace delete
    newline home end mouse-press ctrl-char))

(define (editor-handle e ev)
  (define-values (e* desc) (handle-raw e ev))
  (values
   (if (memq (ui-event-kind ev) ensure-visible-kinds)
       (struct-copy editor e* [window (window-ensure-point (editor-window e*))])
       e*)
   desc))

(define (handle-ctrl e ch)
  (case ch
    [(#\Q #\q) (values (struct-copy editor e [done? #t]) #f)]   ; Ctrl+Q 退出
    [(#\W #\w) (editor-window* e (lambda (w)                   ; Ctrl+W 切换折行
                                   (window-set-mode w
                                     (if (eq? (window-mode w) 'wrap) 'clip 'wrap))))]
    [else (values e #f)]))

;; data = (button x y mods)，x/y 已是 0-based 显示坐标
(define (handle-mouse-press e data)
  (match-define (list btn x y _mods) data)
  (if (eq? btn 'left)
      (let-values ([(line col) (window-screen->point (editor-window e) y x)])
        (if line
            (editor-edit e (lambda (b) (buffer-goto b line col)))
            (values e #f)))
      (values e #f)))

;; data = (dir x y mods)
(define (handle-mouse-scroll e data)
  (match-define (list dir _x _y _mods) data)
  (values (editor-window* e (lambda (w)
                              (window-scroll-visual w (if (eq? dir 'up) -3 3))))
          #f))

(module+ test
  (define e0 (make-editor (buffer-open "hello\nworld") '() 24 80))
  (check-false (editor-done? e0))

  ;; insert-string：desc 透传
  (define-values (e1 d1) (editor-handle e0 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer->string (editor-buffer e1)) "Xhello\nworld")
  (check-equal? d1 (edit-desc 0 0 0 0 "X"))

  ;; 移动：desc = #f
  (define-values (e-up d-up) (editor-handle e0 (ui-event 'move-up '())))
  (check-equal? (buffer-point (editor-buffer e-up)) (cursor 0 0))
  (check-false d-up)
  (define-values (e-rt d-rt) (editor-handle e0 (ui-event 'move-right '())))
  (check-equal? (buffer-point (editor-buffer e-rt)) (cursor 0 1))
  (check-false d-rt)

  ;; resize
  (define-values (e4 d4) (editor-handle e0 (ui-event 'resize (list 30 100))))
  (check-equal? (window-height (editor-window e4)) 30)
  (check-equal? (window-width  (editor-window e4)) 100)
  (check-false d4)

  ;; Ctrl+Q 退出
  (define-values (e-q d-q) (editor-handle e0 (ui-event 'ctrl-char (list #\Q))))
  (check-true (editor-done? e-q))
  (check-false d-q)

  ;; mouse-press：(2,1) → 第 1 行第 2 列
  (define-values (e6 d6) (editor-handle e0 (ui-event 'mouse-press (list 'left 2 1 '()))))
  (check-equal? (buffer-point (editor-buffer e6)) (cursor 1 2))
  (check-false d6)

  ;; 插件随编辑运行
  (define (tag-b b) (buffer-put-text-property b 0 0 1 'face 'bold))
  (define e7 (make-editor (buffer-open "ab") (list tag-b) 24 80))
  (define-values (e8 d8) (editor-handle e7 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer-get-text-property (editor-buffer e8) 0 0 'face) 'bold)
  (check-equal? d8 (edit-desc 0 0 0 0 "X"))

  (displayln "editor.rkt: all tests passed"))
