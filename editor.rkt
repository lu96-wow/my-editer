#lang racket

(require "events.rkt" "cursor.rkt" "buffer.rkt" "window.rkt"
         "plugin.rkt" "view.rkt" "slot.rkt" rackunit)

;;; editor.rkt —— 应用层：编辑器状态 + 命令 + 事件处理
;;;
;;; 状态 = window（buffer 引用 + point）+ keymap + buffer 插件 + view 插件。
;;;   两个插件 slot：
;;;   - buffer 插件：buffer→buffer，吃 dirty（语法高亮 / lint / 折叠）
;;;   - view 插件：  window→status-seg，供状态行（行列 / 模式 / …）
;;;   一个扩展点：
;;;   - keymap：     ui-event-kind → 命令；命令 = (-> editor ui-event (values editor desc))

(provide
 (struct-out editor)
 default-keymap
 make-editor
 editor-handle
 editor-status
 editor-done?)

(struct editor (window keymap plugins view-plugins done?) #:transparent)

(define (editor-buffer e) (window-buffer (editor-window e)))

(define (make-editor b0 [plugins '()] [view-plugins '()] [height 24] [width 80])
  (define b* (run-plugins-init b0 plugins))
  (editor (window-open b* height width)
          default-keymap
          plugins
          view-plugins
          #f))

;; f : window -> (values window desc)。在 window 上执行命令，跑 buffer 插件，desc 透传。
(define (editor-edit e f)
  (define-values (w1 desc) (f (editor-window e)))
  (define b* (run-plugins (window-buffer w1) (editor-plugins e)))
  (values (struct-copy editor e
            [window (window-set-buffer w1 b*)])
          desc))

;; 只改 window（滚动 / 尺寸等）：无编辑，desc 恒 #f。
(define (editor-window* e f)
  (values (struct-copy editor e [window (f (editor-window e))]) #f))

;; 视口派生：跑 view 插件，得到状态行段（供后端渲染）。
(define (editor-status e)
  (run-view-plugins (editor-window e) (editor-view-plugins e)))

;;; ---------- 命令（扩展点：输入 → 命令）----------

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
            (editor-edit e (lambda (w) (window-goto w line col)))
            (values e #f)))
      (values e #f)))

;; data = (dir x y mods)
(define (handle-mouse-scroll e data)
  (match-define (list dir _x _y _mods) data)
  (editor-window* e (lambda (w)
                      (window-scroll-visual w (if (eq? dir 'up) -3 3)))))

;; 命令 = (-> editor ui-event (values editor desc))
(define (cmd-insert-text e ev)
  (editor-edit e (lambda (w) (window-insert-text w (car (ui-event-data ev))))))

(define default-keymap
  (hash
   'insert-string cmd-insert-text
   'move-up       (lambda (e ev) (editor-edit e (lambda (w) (window-visual-move w -1))))
   'move-down     (lambda (e ev) (editor-edit e (lambda (w) (window-visual-move w +1))))
   'move-left     (lambda (e ev) (editor-edit e window-left))
   'move-right    (lambda (e ev) (editor-edit e window-right))
   'backspace     (lambda (e ev) (editor-edit e window-backspace))
   'delete        (lambda (e ev) (editor-edit e window-delete))
   'newline       (lambda (e ev) (editor-edit e window-newline))
   'home          (lambda (e ev) (editor-edit e window-home))
   'end           (lambda (e ev) (editor-edit e window-end))
   'pageup        (lambda (e ev) (editor-window* e (lambda (w) (window-scroll-visual w (- (window-height w) 1)))))
   'pagedown      (lambda (e ev) (editor-window* e (lambda (w) (window-scroll-visual w (- (window-height w) 1)))))
   'ctrl-char     (lambda (e ev) (handle-ctrl e (car (ui-event-data ev))))
   'resize        (lambda (e ev) (match-define (list rows cols) (ui-event-data ev))
                                  (editor-window* e (lambda (w) (window-set-size w rows cols))))
   'mouse-press   (lambda (e ev) (handle-mouse-press e (ui-event-data ev)))
   'mouse-scroll  (lambda (e ev) (handle-mouse-scroll e (ui-event-data ev)))
   'quit          (lambda (e ev) (values (struct-copy editor e [done? #t]) #f))))

;; 统一返回 (values editor desc)。desc = 本次编辑的 edit-desc；非编辑事件为 #f。
(define (handle-raw e ev)
  (define cmd (hash-ref (editor-keymap e) (ui-event-kind ev) #f))
  (if cmd (cmd e ev) (values e #f)))

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

(module+ test
  (define e0 (make-editor (buffer-open "hello\nworld") '() '() 24 80))
  (check-false (editor-done? e0))

  ;; insert-string：desc 透传，point 在 window
  (define-values (e1 d1) (editor-handle e0 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer->string (editor-buffer e1)) "Xhello\nworld")
  (check-equal? (window-point (editor-window e1)) (cursor 0 1))
  (check-equal? d1 (edit-desc 0 0 0 0 "X"))

  ;; 移动：desc = #f
  (define-values (e-up d-up) (editor-handle e0 (ui-event 'move-up '())))
  (check-equal? (window-point (editor-window e-up)) (cursor 0 0))
  (check-false d-up)
  (define-values (e-rt d-rt) (editor-handle e0 (ui-event 'move-right '())))
  (check-equal? (window-point (editor-window e-rt)) (cursor 0 1))
  (check-false d-rt)
  (define-values (e-dn d-dn) (editor-handle e0 (ui-event 'move-down '())))
  (check-equal? (window-point (editor-window e-dn)) (cursor 1 0))
  (check-false d-dn)
  (define-values (e-lf d-lf) (editor-handle e0 (ui-event 'move-left '())))
  (check-equal? (window-point (editor-window e-lf)) (cursor 0 0))
  (check-false d-lf)

  ;; backspace / delete / newline 编辑
  (define-values (e-bs d-bs) (editor-handle e0 (ui-event 'backspace '())))
  (check-equal? (buffer->string (editor-buffer e-bs)) "hello\nworld")
  (check-false d-bs)
  (define-values (e-nl d-nl) (editor-handle e0 (ui-event 'newline '())))
  (check-equal? (buffer->string (editor-buffer e-nl)) "\nhello\nworld")
  (check-equal? d-nl (edit-desc 0 0 0 0 "\n"))

  ;; resize
  (define-values (e4 d4) (editor-handle e0 (ui-event 'resize (list 30 100))))
  (check-equal? (window-height (editor-window e4)) 30)
  (check-equal? (window-width  (editor-window e4)) 100)
  (check-false d4)

  ;; mouse-scroll：只滚动，不动光标，desc = #f
  (define-values (e-sc d-sc) (editor-handle e0 (ui-event 'mouse-scroll (list 'down 0 0 '()))))
  (check-equal? (window-top-line (editor-window e-sc)) 3)
  (check-false d-sc)

  ;; Ctrl+Q 退出
  (define-values (e-q d-q) (editor-handle e0 (ui-event 'ctrl-char (list #\Q))))
  (check-true (editor-done? e-q))
  (check-false d-q)

  ;; mouse-press：(2,1) → 第 1 行第 2 列
  (define-values (e6 d6) (editor-handle e0 (ui-event 'mouse-press (list 'left 2 1 '()))))
  (check-equal? (window-point (editor-window e6)) (cursor 1 2))
  (check-false d6)

  ;; buffer 插件随编辑运行
  (define (tag-b b) (buffer-put-text-property b 0 0 1 'face 'bold))
  (define e7 (make-editor (buffer-open "ab") (list tag-b) '() 24 80))
  (define-values (e8 d8) (editor-handle e7 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer-get-text-property (editor-buffer e8) 0 0 'face) 'bold)
  (check-equal? d8 (edit-desc 0 0 0 0 "X"))

  ;; view 插件：状态行
  (define (rowcol w)
    (define p (window-point w))
    (list (status-seg (format "Ln ~a Col ~a" (add1 (cursor-line p)) (add1 (cursor-col p))) #f)))
  (define e9 (make-editor (buffer-open "hello\nworld") '() (list rowcol) 24 80))
  (check-equal? (status-segs->string (editor-status e9)) "Ln 1 Col 1")
  (define-values (e10 _1) (editor-handle e9 (ui-event 'move-right '())))
  (check-equal? (status-segs->string (editor-status e10)) "Ln 1 Col 2")

  ;; keymap 可扩展：把 move-left 换成 move-right
  (define custom-keymap
    (hash-set default-keymap 'move-left
              (lambda (e ev) (editor-edit e window-right))))
  (define e11 (struct-copy editor e0 [keymap custom-keymap]))
  (define-values (e12 _2) (editor-handle e11 (ui-event 'move-left '())))
  (check-equal? (window-point (editor-window e12)) (cursor 0 1))

  (displayln "editor.rkt: all tests passed"))
