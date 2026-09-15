#lang racket

(require racket/list
         "../core/view/events.rkt" "../core/text/cursor.rkt" "../core/text/buffer.rkt"
         "../core/view/window.rkt" "../core/view/frame.rkt" "../core/view/view.rkt"
         "../plugin/buffer-plugin.rkt" "../plugin/view-plugin.rkt" rackunit)

;;; event.rkt —— 事件层：把 ui-event 翻译成 frame 状态转移（组合根）
;;;
;;; 这里不是「编辑器」，只做：路由输入 → 命令 → frame 状态转移 + 插件运行。
;;;   状态   = frame（core/view 的机制：一组 window + 布局 + 焦点）
;;;   策略   = config（keymap + 插件，常量）
;;;   控制流 = done?（返回值，不落状态）
;;; 真正的 editor 由使用者在 ui/tui 拼装：buffer + frame + config + tui。

(provide
 (struct-out config)
 make-config
 default-keymap
 default-mgmt-keymap
 frame-handle
 frame-status)

;;; ---------- 策略 bundle（常量） ----------

(struct config (keymap mgmt-keymap plugins view-plugins) #:transparent)
;; keymap      : kind -> (-> window ui-event (values window desc))           窗口级命令
;; mgmt-keymap : kind -> (-> frame  ui-event (values frame desc done?))      frame 级命令
;; plugins     : (listof (-> buffer buffer))
;; view-plugins: (listof (-> window (listof status-seg)))

(define (make-config [keymap default-keymap] [mgmt-keymap default-mgmt-keymap]
                     [plugins '()] [view-plugins '()])
  (config keymap mgmt-keymap plugins view-plugins))

;;; ---------- 窗口级命令（作用于 active window） ----------

(define (cmd-insert-text w ev)
  (window-insert-text w (car (ui-event-data ev))))

(define default-keymap
  (hash
   'insert-string cmd-insert-text
   'move-up       (lambda (w ev) (window-visual-move w -1))
   'move-down     (lambda (w ev) (window-visual-move w +1))
   'move-left     (lambda (w ev) (window-left w))
   'move-right    (lambda (w ev) (window-right w))
   'backspace     (lambda (w ev) (window-backspace w))
   'delete        (lambda (w ev) (window-delete w))
   'newline       (lambda (w ev) (window-newline w))
   'home          (lambda (w ev) (window-home w))
   'end           (lambda (w ev) (window-end w))
   'pageup        (lambda (w ev) (values (window-scroll-visual w (- (window-height w) 1)) #f))
   'pagedown      (lambda (w ev) (values (window-scroll-visual w (- (window-height w) 1)) #f))))

;;; ---------- frame 级命令 ----------

;; Ctrl+字母：退出 / 折行 / 窗口管理
(define (mgmt-ctrl f ev)
  (define ch (car (ui-event-data ev)))
  (case ch
    [(#\Q #\q) (values f #f #t)]                                     ; 退出
    [(#\W #\w) (values (toggle-active-mode f) #f #f)]                ; 切换折行
    [(#\V #\v) (values (frame-split f 'vsplit) #f #f)]               ; 上下分屏
    [(#\B #\b) (values (frame-split f 'hsplit) #f #f)]               ; 左右分屏
    [(#\O #\o) (values (frame-ensure-active (frame-focus f 'next)) #f #f)]
    [(#\P #\p) (values (frame-ensure-active (frame-focus f 'prev)) #f #f)]
    [(#\X #\x) (values (frame-close f) #f #f)]                       ; 关窗口
    [else (values f #f #f)]))

(define (toggle-active-mode f)
  (define id (frame-active f))
  (define w (frame-active-window f))
  (struct-copy frame f
    [windows (hash-set (frame-windows f) id
                       (window-set-mode w
                         (if (eq? (window-mode w) 'wrap) 'clip 'wrap)))]))

;; data = (button x y mods)，x/y 0-based 屏幕坐标
(define (handle-mouse-press f ev)
  (match-define (list btn x y _mods) (ui-event-data ev))
  (if (eq? btn 'left)
      (let ([id (frame-window-at f x y)])
        (if (not id)
            (values f #f #f)
            (let* ([f1 (struct-copy frame f [active id])]
                   [rect (frame-window-rect f1 id)]
                   [w (frame-window f1 id)])
              (define-values (line col)
                (if rect
                    (window-screen->point w (- y (list-ref rect 2))
                                            (- x (list-ref rect 1)))
                    (values #f #f)))
              (cond
                [(not line) (values f1 #f #f)]
                [else
                 (define w1 (window-set-point w (cursor line col)))
                 (values (frame-ensure-active
                          (struct-copy frame f1
                            [windows (hash-set (frame-windows f1) id w1)]))
                         #f #f)]))))
      (values f #f #f)))

;; data = (dir x y mods)
(define (handle-mouse-scroll f ev)
  (match-define (list dir x y _mods) (ui-event-data ev))
  (define id (or (frame-window-at f x y) (frame-active f)))
  (if (not id)
      (values f #f #f)
      (values (struct-copy frame f
                [windows (hash-set (frame-windows f) id
                                   (window-scroll-visual (frame-window f id)
                                                         (if (eq? dir 'up) -3 3)))])
              #f #f)))

(define default-mgmt-keymap
  (hash
   'ctrl-char     mgmt-ctrl
   'mouse-press   handle-mouse-press
   'mouse-scroll  handle-mouse-scroll
   'resize        (lambda (f ev)
                    (match-define (list r c) (ui-event-data ev))
                    (values (frame-resize f r c) #f #f))
   'quit          (lambda (f ev) (values f #f #t))))

;;; ---------- 事件处理 ----------

;; 这些事件会移动光标 → 之后让窗口跟随
(define ensure-visible-kinds
  '(insert-string move-up move-down move-left move-right backspace delete
    newline home end))

;; 在 active 窗口上执行窗口级命令：编辑 → 跑 buffer 插件 → linked 同步
(define (frame-run-window-cmd cfg f cmd ev)
  (define id (frame-active f))
  (define old-b (window-buffer (frame-window f id)))
  (define-values (f1 desc) (frame-edit-active f id (lambda (w) (cmd w ev))))
  (define f2
    (cond
      [(not desc) f1]
      [else
       (define b* (run-plugins (window-buffer (frame-window f1 id)) (config-plugins cfg)))
       (frame-sync-buffer f1 id old-b b* desc)]))
  (values (if (memq (ui-event-kind ev) ensure-visible-kinds)
              (frame-ensure-active f2)
              f2)
          desc
          #f))

(define (frame-handle cfg f ev)
  (define kind (ui-event-kind ev))
  (define mgmt (hash-ref (config-mgmt-keymap cfg) kind #f))
  (cond
    [mgmt (mgmt f ev)]
    [else
     (define cmd (hash-ref (config-keymap cfg) kind #f))
     (if cmd
         (frame-run-window-cmd cfg f cmd ev)
         (values f #f #f))]))

;;; ---------- 状态行 ----------

(define (frame-status cfg f)
  (define order (frame-leaf-order f))
  (define idx (index-of order (frame-active f)))
  (append
   (list (status-seg (format "[~a/~a]" (add1 (or idx 0)) (frame-window-count f)) 'mode))
   (run-view-plugins (frame-active-window f) (config-view-plugins cfg))))

;;; ---------- 测试 ----------

(module+ test
  (define cfg0 (make-config))
  (define f0 (frame-open (buffer-open "hello\nworld") 24 80))

  ;; insert-string：desc 透传，point 前进
  (define-values (f1 d1 _d1) (frame-handle cfg0 f0 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer->string (window-buffer (frame-active-window f1))) "Xhello\nworld")
  (check-equal? (window-point (frame-active-window f1)) (cursor 0 1))
  (check-equal? d1 (edit-desc 0 0 0 0 "X"))

  ;; 移动：desc = #f
  (define-values (f-rt d-rt _dr) (frame-handle cfg0 f0 (ui-event 'move-right '())))
  (check-equal? (window-point (frame-active-window f-rt)) (cursor 0 1))
  (check-false d-rt)
  (define-values (f-dn _a1 _a2) (frame-handle cfg0 f0 (ui-event 'move-down '())))
  (check-equal? (window-point (frame-active-window f-dn)) (cursor 1 0))

  ;; newline 编辑
  (define-values (f-nl d-nl _dnl) (frame-handle cfg0 f0 (ui-event 'newline '())))
  (check-equal? (buffer->string (window-buffer (frame-active-window f-nl))) "\nhello\nworld")
  (check-equal? d-nl (edit-desc 0 0 0 0 "\n"))

  ;; resize
  (define-values (f4 _b1 _b2) (frame-handle cfg0 f0 (ui-event 'resize (list 30 100))))
  (check-equal? (frame-rows f4) 30)
  (check-equal? (frame-cols f4) 100)

  ;; mouse-scroll：只滚动，不动光标
  (define-values (f-sc _c1 _c2) (frame-handle cfg0 f0 (ui-event 'mouse-scroll (list 'down 0 0 '()))))
  (check-equal? (window-top-line (frame-active-window f-sc)) 3)

  ;; mouse-press：定位 point（曾有两个 bug：单值绑定 + x/y 顺序写反）
  (define f-m (frame-open (buffer-open "hello\nworld\nfoo") 3 10))
  (define-values (f-m1 _m1 _m2) (frame-handle cfg0 f-m (ui-event 'mouse-press (list 'left 3 1 '()))))
  (check-equal? (window-point (frame-active-window f-m1)) (cursor 1 3))
  (define-values (f-m2 _m3 _m4) (frame-handle cfg0 f-m1 (ui-event 'mouse-press (list 'left 0 5 '()))))
  (check-equal? (window-point (frame-active-window f-m2)) (cursor 1 3))  ; 越界不变
  ;; 分屏后点击右侧窗口 → focus 到右侧 + point 相对偏移
  (define f-msp (frame-open (buffer-open "ab") 2 10))
  (define-values (f-msp2 _m5 _m6) (frame-handle cfg0 f-msp (ui-event 'ctrl-char (list #\B))))
  (define-values (f-m3 _m7 _m8) (frame-handle cfg0 f-msp2 (ui-event 'mouse-press (list 'left 7 0 '()))))
  (check-equal? (frame-active f-m3) 1)
  (check-equal? (window-point (frame-active-window f-m3)) (cursor 0 2))

  ;; Ctrl+Q 退出 → done?
  (define-values (_fq _dq done-q) (frame-handle cfg0 f0 (ui-event 'ctrl-char (list #\Q))))
  (check-true done-q)
  (define-values (_fr _dr2 done-r) (frame-handle cfg0 f0 (ui-event 'move-right '())))
  (check-false done-r)

  ;; 分屏 + linked 同步（Ctrl+B 左右分）
  (define b2 (buffer-open "ab"))
  (define f-sp (frame-open b2 3 10))
  (define-values (f-sp2 _sp1 _sp2) (frame-handle cfg0 f-sp (ui-event 'ctrl-char (list #\B))))
  (check-equal? (frame-window-count f-sp2) 2)
  (check-equal? (frame-active f-sp2) 1)
  (define-values (f-ins _e1 _e2) (frame-handle cfg0 f-sp2 (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer->string (window-buffer (frame-window f-ins 0))) "Xab")
  (check-equal? (buffer->string (window-buffer (frame-window f-ins 1))) "Xab")
  (check-equal? (window-point (frame-window f-ins 0)) (cursor 0 0))
  (check-equal? (window-point (frame-window f-ins 1)) (cursor 0 1))

  ;; buffer 插件随编辑运行（共享 buffer，插件结果两边可见）
  (define (tag-b b) (buffer-put-text-property b 0 0 1 'face 'bold))
  (define cfg-tag (make-config default-keymap default-mgmt-keymap (list tag-b) '()))
  (define f-tag (frame-open (buffer-open "ab") 24 80))
  (define-values (f-tag2 _f1 _f2) (frame-handle cfg-tag f-tag (ui-event 'insert-string (list "X"))))
  (check-equal? (buffer-get-text-property (window-buffer (frame-window f-tag2 0)) 0 0 'face) 'bold)

  ;; view 插件：状态行
  (define (rowcol w)
    (define p (window-point w))
    (list (status-seg (format "Ln ~a Col ~a" (add1 (cursor-line p)) (add1 (cursor-col p))) #f)))
  (define cfg-v (make-config default-keymap default-mgmt-keymap '() (list rowcol)))
  (define f-v (frame-open (buffer-open "hello\nworld") 24 80))
  (check-equal? (status-segs->string (frame-status cfg-v f-v)) "[1/1]Ln 1 Col 1")
  (define-values (f-v2 _g1 _g2) (frame-handle cfg-v f-v (ui-event 'move-right '())))
  (check-equal? (status-segs->string (frame-status cfg-v f-v2)) "[1/1]Ln 1 Col 2")

  ;; keymap 可扩展：把 move-left 换成 move-right
  (define custom-keymap (hash-set default-keymap 'move-left (lambda (w ev) (window-right w))))
  (define cfg-c (make-config custom-keymap))
  (define-values (f-c _h1 _h2) (frame-handle cfg-c f0 (ui-event 'move-left '())))
  (check-equal? (window-point (frame-active-window f-c)) (cursor 0 1))

  (displayln "event.rkt: all tests passed"))
