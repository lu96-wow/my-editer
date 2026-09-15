#lang racket

(require "../core/view/events.rkt" "../core/doc/cursor.rkt" "../core/doc/buffer.rkt"
         "../core/view/window.rkt" "../plugin/buffer-plugin.rkt"
         "../core/view/view.rkt" "../plugin/view-plugin.rkt" rackunit)

;;; app/event.rkt —— 事件层：会话状态 + 命令/keymap + 事件处理
;;;
;;; 这里不是「编辑器」，只是把 ui-event 翻译成状态转移的交互会话（session）。
;;; 真正的 editor 由使用者用接口自行拼装：buffer + window + plugin + session + ui
;;; （见 ui/tui 的 run-tui：它把 session + paint + tui 拼成一个可运行的编辑器）。
;;;
;;; session 状态 = window（buffer 引用 + point）+ keymap + 两个插件 slot + done?。
;;;   - buffer 插件：buffer→buffer，吃 dirty（语法高亮 / lint / 折叠）
;;;   - view 插件：  window→status-seg，供状态行（行列 / 模式 / …）
;;;   - keymap：     ui-event-kind → 命令；命令 = (-> session ui-event (values session desc))

(provide
 (struct-out session)
 default-keymap
 make-session
 session-handle
 session-status
 session-done?)

(struct session (window keymap plugins view-plugins done?) #:transparent)

(define (session-buffer s) (window-buffer (session-window s)))

(define (make-session b0 [plugins '()] [view-plugins '()] [height 24] [width 80])
  (define b* (run-plugins-init b0 plugins))
  (session (window-open b* height width)
           default-keymap
           plugins
           view-plugins
           #f))

;; f : window -> (values window desc)。在 window 上执行命令，跑 buffer 插件，desc 透传。
(define (session-edit s f)
  (define-values (w1 desc) (f (session-window s)))
  (define b* (run-plugins (window-buffer w1) (session-plugins s)))
  (values (struct-copy session s
            [window (window-set-buffer w1 b*)])
          desc))

;; 只改 window（滚动 / 尺寸等）：无编辑，desc 恒 #f。
(define (session-window* s f)
  (values (struct-copy session s [window (f (session-window s))]) #f))

;; 视口派生：跑 view 插件，得到状态行段（供后端渲染）。
(define (session-status s)
  (run-view-plugins (session-window s) (session-view-plugins s)))

;;; ---------- 命令（扩展点：输入 → 命令）----------

(define (handle-ctrl s ch)
  (case ch
    [(#\Q #\q) (values (struct-copy session s [done? #t]) #f)]   ; Ctrl+Q 退出
    [(#\W #\w) (session-window* s (lambda (w)                  ; Ctrl+W 切换折行
                                    (window-set-mode w
                                      (if (eq? (window-mode w) 'wrap) 'clip 'wrap))))]
    [else (values s #f)]))

;; data = (button x y mods)，x/y 已是 0-based 显示坐标
(define (handle-mouse-press s data)
  (match-define (list btn x y _mods) data)
  (if (eq? btn 'left)
      (let-values ([(line col) (window-screen->point (session-window s) y x)])
        (if line
            (session-edit s (lambda (w) (window-goto w line col)))
            (values s #f)))
      (values s #f)))

;; data = (dir x y mods)
(define (handle-mouse-scroll s data)
  (match-define (list dir _x _y _mods) data)
  (session-window* s (lambda (w)
                       (window-scroll-visual w (if (eq? dir 'up) -3 3)))))

;; 命令 = (-> session ui-event (values session desc))
(define (cmd-insert-text s ev)
  (session-edit s (lambda (w) (window-insert-text w (car (ui-event-data ev))))))

(define default-keymap
  (hash
   'insert-string cmd-insert-text
   'move-up       (lambda (s ev) (session-edit s (lambda (w) (window-visual-move w -1))))
   'move-down     (lambda (s ev) (session-edit s (lambda (w) (window-visual-move w +1))))
   'move-left     (lambda (s ev) (session-edit s window-left))
   'move-right    (lambda (s ev) (session-edit s window-right))
   'backspace     (lambda (s ev) (session-edit s window-backspace))
   'delete        (lambda (s ev) (session-edit s window-delete))
   'newline       (lambda (s ev) (session-edit s window-newline))
   'home          (lambda (s ev) (session-edit s window-home))
   'end           (lambda (s ev) (session-edit s window-end))
   'pageup        (lambda (s ev) (session-window* s (lambda (w) (window-scroll-visual w (- (window-height w) 1)))))
   'pagedown      (lambda (s ev) (session-window* s (lambda (w) (window-scroll-visual w (- (window-height w) 1)))))
   'ctrl-char     (lambda (s ev) (handle-ctrl s (car (ui-event-data ev))))
   'resize        (lambda (s ev) (match-define (list rows cols) (ui-event-data ev))
                                  (session-window* s (lambda (w) (window-set-size w rows cols))))
   'mouse-press   (lambda (s ev) (handle-mouse-press s (ui-event-data ev)))
   'mouse-scroll  (lambda (s ev) (handle-mouse-scroll s (ui-event-data ev)))
   'quit          (lambda (s ev) (values (struct-copy session s [done? #t]) #f))))

;; 统一返回 (values session desc)。desc = 本次编辑的 edit-desc；非编辑事件为 #f。
(define (handle-raw s ev)
  (define cmd (hash-ref (session-keymap s) (ui-event-kind ev) #f))
  (if cmd (cmd s ev) (values s #f)))

;; 这些事件会移动光标 → 之后让窗口跟随（滚动/限位）
(define ensure-visible-kinds
  '(insert-string move-up move-down move-left move-right backspace delete
    newline home end mouse-press ctrl-char))

(define (session-handle s ev)
  (define-values (s* desc) (handle-raw s ev))
  (values
   (if (memq (ui-event-kind ev) ensure-visible-kinds)
       (struct-copy session s* [window (window-ensure-point (session-window s*))])
       s*)
   desc))

(module+ test
  (define s0 (make-session (buffer-open "hello\nworld") '() '() 24 80))
  (check-false (session-done? s0))

  ;; insert-string：desc 透传，point 在 window
  (define-values (s1 d1) (session-handle s0 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer->string (session-buffer s1)) "Xhello\nworld")
  (check-equal? (window-point (session-window s1)) (cursor 0 1))
  (check-equal? d1 (edit-desc 0 0 0 0 "X"))

  ;; 移动：desc = #f
  (define-values (s-up d-up) (session-handle s0 (ui-event 'move-up '())))
  (check-equal? (window-point (session-window s-up)) (cursor 0 0))
  (check-false d-up)
  (define-values (s-rt d-rt) (session-handle s0 (ui-event 'move-right '())))
  (check-equal? (window-point (session-window s-rt)) (cursor 0 1))
  (check-false d-rt)
  (define-values (s-dn d-dn) (session-handle s0 (ui-event 'move-down '())))
  (check-equal? (window-point (session-window s-dn)) (cursor 1 0))
  (check-false d-dn)
  (define-values (s-lf d-lf) (session-handle s0 (ui-event 'move-left '())))
  (check-equal? (window-point (session-window s-lf)) (cursor 0 0))
  (check-false d-lf)

  ;; backspace / delete / newline 编辑
  (define-values (s-bs d-bs) (session-handle s0 (ui-event 'backspace '())))
  (check-equal? (buffer->string (session-buffer s-bs)) "hello\nworld")
  (check-false d-bs)
  (define-values (s-nl d-nl) (session-handle s0 (ui-event 'newline '())))
  (check-equal? (buffer->string (session-buffer s-nl)) "\nhello\nworld")
  (check-equal? d-nl (edit-desc 0 0 0 0 "\n"))

  ;; resize
  (define-values (s4 d4) (session-handle s0 (ui-event 'resize (list 30 100))))
  (check-equal? (window-height (session-window s4)) 30)
  (check-equal? (window-width  (session-window s4)) 100)
  (check-false d4)

  ;; mouse-scroll：只滚动，不动光标，desc = #f
  (define-values (s-sc d-sc) (session-handle s0 (ui-event 'mouse-scroll (list 'down 0 0 '()))))
  (check-equal? (window-top-line (session-window s-sc)) 3)
  (check-false d-sc)

  ;; Ctrl+Q 退出
  (define-values (s-q d-q) (session-handle s0 (ui-event 'ctrl-char (list #\Q))))
  (check-true (session-done? s-q))
  (check-false d-q)

  ;; mouse-press：(2,1) → 第 1 行第 2 列
  (define-values (s6 d6) (session-handle s0 (ui-event 'mouse-press (list 'left 2 1 '()))))
  (check-equal? (window-point (session-window s6)) (cursor 1 2))
  (check-false d6)

  ;; buffer 插件随编辑运行
  (define (tag-b b) (buffer-put-text-property b 0 0 1 'face 'bold))
  (define s7 (make-session (buffer-open "ab") (list tag-b) '() 24 80))
  (define-values (s8 d8) (session-handle s7 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer-get-text-property (session-buffer s8) 0 0 'face) 'bold)
  (check-equal? d8 (edit-desc 0 0 0 0 "X"))

  ;; view 插件：状态行
  (define (rowcol w)
    (define p (window-point w))
    (list (status-seg (format "Ln ~a Col ~a" (add1 (cursor-line p)) (add1 (cursor-col p))) #f)))
  (define s9 (make-session (buffer-open "hello\nworld") '() (list rowcol) 24 80))
  (check-equal? (status-segs->string (session-status s9)) "Ln 1 Col 1")
  (define-values (s10 _1) (session-handle s9 (ui-event 'move-right '())))
  (check-equal? (status-segs->string (session-status s10)) "Ln 1 Col 2")

  ;; keymap 可扩展：把 move-left 换成 move-right
  (define custom-keymap
    (hash-set default-keymap 'move-left
              (lambda (s ev) (session-edit s window-right))))
  (define s11 (struct-copy session s0 [keymap custom-keymap]))
  (define-values (s12 _2) (session-handle s11 (ui-event 'move-left '())))
  (check-equal? (window-point (session-window s12)) (cursor 0 1))

  (displayln "event.rkt: all tests passed"))
