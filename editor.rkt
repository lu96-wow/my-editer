#lang racket

(require "events.rkt" "cursor.rkt" "buffer.rkt" "window.rkt"
         "plugin.rkt" "width.rkt" rackunit)

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
  (define b* (run-plugins (f b) (editor-plugins e)))
  (struct-copy editor e
    [buffer b*]
    [window (window-set-buffer (editor-window e) b*)]))

;; 只改 window（滚动 / 尺寸等）。
(define (editor-window* e f)
  (struct-copy editor e [window (f (editor-window e))]))

(define (editor-handle e ev)
  (match (ui-event-kind ev)
    ['insert-string
     (for/fold ([e e]) ([ch (in-string (car (ui-event-data ev)))])
       (editor-edit e (lambda (b) (buffer-insert b ch))))]
    ['move-up    (editor-edit e buffer-up)]
    ['move-down  (editor-edit e buffer-down)]
    ['move-left  (editor-edit e buffer-left)]
    ['move-right (editor-edit e buffer-right)]
    ['backspace  (editor-edit e buffer-backspace)]
    ['delete     (editor-edit e buffer-delete)]
    ['newline    (editor-edit e buffer-newline)]
    ['home       (editor-edit e buffer-home)]
    ['end        (editor-edit e buffer-end)]
    ['pageup     (editor-window* e (lambda (w) (window-scroll w (- (window-height w) 1))))]
    ['pagedown   (editor-window* e (lambda (w) (window-scroll w (- (window-height w) 1))))]
    ['ctrl-char  (handle-ctrl e (car (ui-event-data ev)))]
    ['resize     (match-define (list rows cols) (ui-event-data ev))
                 (editor-window* e (lambda (w) (window-set-size w rows cols)))]
    ['mouse-press  (handle-mouse-press e (ui-event-data ev))]
    ['mouse-scroll (handle-mouse-scroll e (ui-event-data ev))]
    ['quit       (struct-copy editor e [done? #t])]
    [_ e]))

(define (handle-ctrl e ch)
  (case ch
    [(#\Q #\q) (struct-copy editor e [done? #t])]   ; Ctrl+Q 退出
    [else e]))

;; data = (button x y mods)，x/y 已是 0-based 显示坐标
(define (handle-mouse-press e data)
  (match-define (list btn x y _mods) data)
  (define w (editor-window e))
  (define b (editor-buffer e))
  (if (eq? btn 'left)
      (let* ([line (+ y (window-top-line w))]
             [n    (buffer-line-count b)])
        (if (< line n)
            (let* ([text (buffer-line-ref b line)]
                   [col  (column->index text (+ x (window-left-col w)))])
              (editor-edit e (lambda (b) (buffer-goto b line col))))
            e))
      e))

;; data = (dir x y mods)
(define (handle-mouse-scroll e data)
  (match-define (list dir _x _y _mods) data)
  (editor-window* e (lambda (w)
                      (window-scroll w (if (eq? dir 'up) -3 3)))))

(module+ test
  (define e0 (make-editor (buffer-open "hello\nworld") '() 24 80))
  (check-false (editor-done? e0))

  ;; insert-string
  (define e1 (editor-handle e0 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer->string (editor-buffer e1)) "Xhello\nworld")

  ;; 移动
  (check-equal? (buffer-point (editor-buffer (editor-handle e0 (ui-event 'move-up '()))))
                (cursor 0 0))
  (check-equal? (buffer-point (editor-buffer (editor-handle e0 (ui-event 'move-right '()))))
                (cursor 0 1))

  ;; resize
  (define e4 (editor-handle e0 (ui-event 'resize (list 30 100))))
  (check-equal? (window-height (editor-window e4)) 30)
  (check-equal? (window-width  (editor-window e4)) 100)

  ;; Ctrl+Q 退出
  (check-true (editor-done? (editor-handle e0 (ui-event 'ctrl-char (list #\Q)))))

  ;; mouse-press：(2,1) → 第 1 行第 2 列
  (define e6 (editor-handle e0 (ui-event 'mouse-press (list 'left 2 1 '()))))
  (check-equal? (buffer-point (editor-buffer e6)) (cursor 1 2))

  ;; 插件随编辑运行
  (define (tag-b b) (buffer-put-text-property b 0 0 1 'face 'bold))
  (define e7 (make-editor (buffer-open "ab") (list tag-b) 24 80))
  (define e8 (editor-handle e7 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer-get-text-property (editor-buffer e8) 0 0 'face) 'bold)

  (displayln "editor.rkt: all tests passed"))
