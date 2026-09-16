#lang racket

(require racket/list
         "../core/view/events.rkt" "../core/text/cursor.rkt" "../core/text/buffer.rkt"
         "../core/view/window.rkt" "../core/view/frame.rkt" "../core/view/view.rkt"
         "../framework/slots.rkt" "../framework/framework.rkt" rackunit)

;;; commands.rkt —— 默认两层命令（参考实现）
;;;
;;; 命令签名：(-> config frame 事件 (values frame desc? done?))
;;; 编辑管线「自由」：命令作者显式调用 edit-active（编辑 → run-plugins → linked 同步 → 跟随）。
;;; 框架不自动跑管线——忘了 frame-sync-buffer 则共享窗口会分叉（自由的代价）。

(provide make-default-commands)

;;; ---------- 手动编辑管线（插件 + linked 同步 + 跟随） ----------

(define (edit-active cfg f edit-fn)
  (define id (frame-active f))
  (define old-b (window-buffer (frame-active-window f)))
  (define-values (f1 desc) (frame-edit-active f id edit-fn))
  (cond
    [(not desc) (values (frame-ensure-active f1) #f #f)]
    [else
     (define b* (run-plugins (window-buffer (frame-window f1 id)) (config-plugins cfg)))
     (define f2 (frame-sync-buffer f1 id old-b b* desc))
     (values (frame-ensure-active f2) desc #f)]))

;;; ---------- 窗口级命令 ----------

(define (on-text cfg f ev)
  (edit-active cfg f (lambda (w) (window-insert-text w (text-event-text ev)))))

(define (on-key-window cfg f ev)
  (edit-active cfg f
    (lambda (w)
      (case (key-event-key ev)
        [(up)       (window-visual-move w -1)]
        [(down)     (window-visual-move w +1)]
        [(left)     (window-left w)]
        [(right)    (window-right w)]
        [(home)     (window-home w)]
        [(end)      (window-end w)]
        [(pageup)   (values (window-scroll-visual w (- (window-height w) 1)) #f)]
        [(pagedown) (values (window-scroll-visual w (- (window-height w) 1)) #f)]
        [(backspace) (window-backspace w)]
        [(delete)    (window-delete w)]
        [(enter)     (window-newline w)]
        [else (values w #f)]))))

;;; ---------- 帧级命令 ----------

(define (toggle-active-mode f)
  (define id (frame-active f))
  (define w (frame-active-window f))
  (struct-copy frame f
    [windows (hash-set (frame-windows f) id
                       (window-set-mode w
                         (if (eq? (window-mode w) 'wrap) 'clip 'wrap)))]))

(define (on-key-frame cfg f ev)
  (define layout (config-layout cfg))
  (define k (key-event-key ev))
  (define m (key-event-modifiers ev))
  (cond
    [(and (char? k) (modifiers-control m))
     (case k
       [(#\Q #\q) (values f #f #t)]
       [(#\W #\w) (values (toggle-active-mode f) #f #f)]
       [(#\V #\v) (values ((layout-split layout) f 'vsplit) #f #f)]
       [(#\B #\b) (values ((layout-split layout) f 'hsplit) #f #f)]
       [(#\O #\o) (values (focus-next cfg f) #f #f)]
       [(#\P #\p) (values (focus-prev cfg f) #f #f)]
       [(#\X #\x) (values ((layout-close layout) f) #f #f)]
       [else (on-key-window cfg f ev)])]
    [else (on-key-window cfg f ev)]))

(define (focus-next cfg f)
  (define layout (config-layout cfg))
  (define order ((layout-order layout) f))
  (frame-ensure-active (frame-cycle-active f order 'next)))

(define (focus-prev cfg f)
  (define layout (config-layout cfg))
  (define order ((layout-order layout) f))
  (frame-ensure-active (frame-cycle-active f order 'prev)))

(define (on-mouse-press cfg f ev)
  (match-define (mouse-press-event btn x y _m) ev)
  (if (eq? btn 'left)
      (let* ([rects ((layout-rects (config-layout cfg)) f)]
             [id (window-id-at rects x y)])
        (if (not id)
            (values f #f #f)
            (let* ([f1 (frame-set-active f id)]
                   [rect (window-rect rects id)]
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
                 (values (frame-ensure-active (frame-set-window f1 id w1)) #f #f)]))))
      (values f #f #f)))

(define (on-mouse-wheel cfg f ev)
  (match-define (mouse-wheel-event dir x y _m) ev)
  (define rects ((layout-rects (config-layout cfg)) f))
  (define id (or (window-id-at rects x y) (frame-active f)))
  (if (not id)
      (values f #f #f)
      (values (frame-set-window f id
                (window-scroll-visual (frame-window f id) (if (eq? dir 'up) -3 3)))
              #f #f)))

(define (on-resize cfg f ev)
  (match-define (resize-event rows cols) ev)
  (define f1 (frame-resize f rows cols))
  ;; resize 也要立即同步各窗口尺寸（与 split/close 一致）：否则 frame 里的 window
  ;; 尺寸保持旧值，只有等下一次渲染被 frame-pieces 就地修正，命令间读到的尺寸是错的。
  (values (frame-sync-sizes f1 ((layout-rects (config-layout cfg)) f1)) #f #f))

(define (on-quit cfg f ev)
  (values f #f #t))

;;; ---------- rects 命中辅助 ----------

;; 命中检测：返回 rects 里覆盖 (x,y) 的 window-id，未命中返回 #f。
(define (window-id-at rects x y)
  (for/or ([r (in-list rects)])
    (match-define (list id rx ry rw rh) r)
    (and (<= rx x (+ rx rw -1)) (<= ry y (+ ry rh -1)) id)))

(define (window-rect rects id)
  (for/first ([r (in-list rects)] #:when (= (car r) id)) r))

;;; ---------- 组装 ----------

(define (make-default-commands)
  (values (window-commands on-text on-key-window)
          (frame-commands on-key-frame on-mouse-press on-mouse-wheel on-resize on-quit)))

;;; ---------- 测试 ----------

(module+ test
  (require "layout-tree.rkt" "compose-line.rkt" "../framework/framework.rkt")

  (define-values (wc fc) (make-default-commands))
  (define cfg (make-config #:window-commands wc #:frame-commands fc
                           #:layout tree-layout #:compose line-compose
                           #:plugins '() #:view-plugins '()
                           #:theme (hash)))
  (define f0 (frame-open (buffer-open "hello\nworld") 3 20))

  ;; 插入文本
  (define-values (f1 d1 _) (framework-handle cfg f0 (text-event "X" (modifiers #f #f #f #f))))
  (check-equal? (buffer->string (window-buffer (frame-active-window f1))) "Xhello\nworld")
  (check-equal? d1 (edit-desc 0 0 0 0 "X"))
  (check-equal? (window-point (frame-active-window f1)) (cursor 0 1))

  ;; Ctrl+B 分屏 → linked 同步
  (define-values (f2 _b1 _b2) (framework-handle cfg f1 (key-event #\B (modifiers #t #f #f #f))))
  (check-equal? (frame-window-count f2) 2)
  (check-equal? (frame-active f2) 0)          ; 焦点留原窗口
  (define-values (f3 _c1 _c2) (framework-handle cfg f2 (text-event "Y" (modifiers #f #f #f #f))))
  (check-equal? (buffer->string (window-buffer (frame-window f3 0)))
                (buffer->string (window-buffer (frame-window f3 1))))

  ;; 导航
  (define-values (f4 _d1 _d2) (framework-handle cfg f3 (key-event 'right (modifiers #f #f #f #f))))
  (check-equal? (window-point (frame-active-window f4)) (cursor 0 3))

  ;; 切换焦点
  (define-values (f5 _e1 _e2) (framework-handle cfg f4 (key-event #\O (modifiers #t #f #f #f))))
  (check-equal? (frame-active f5) 1)

  ;; 退出
  (define-values (_fq _dq done-q) (framework-handle cfg f5 (key-event #\Q (modifiers #t #f #f #f))))
  (check-true done-q)

  ;; mouse-press：定位 point（曾有多余括号 bug）
  (define fm (frame-open (buffer-open "hello\nworld\nfoo") 3 11))
  (define-values (fm1 _m1 _m2) (framework-handle cfg fm (mouse-press-event 'left 3 1 (modifiers #f #f #f #f))))
  (check-equal? (window-point (frame-active-window fm1)) (cursor 1 3))
  (define-values (fm2 _m3 _m4) (framework-handle cfg fm1 (mouse-press-event 'left 0 5 (modifiers #f #f #f #f))))
  (check-equal? (window-point (frame-active-window fm2)) (cursor 1 3))  ; 越界不变

  ;; mouse-wheel：只滚动
  (define fw (frame-open (buffer-open "l1\nl2\nl3\nl4\nl5\nl6") 3 11))
  (define-values (fw1 _w1 _w2) (framework-handle cfg fw (mouse-wheel-event 'down 0 0 (modifiers #f #f #f #f))))
  (check-equal? (window-top-line (frame-active-window fw1)) 3)

  ;; resize：同步窗口尺寸
  (define-values (fr1 _r1 _r2) (framework-handle cfg fw (resize-event 5 20)))
  (check-equal? (window-width (frame-active-window fr1)) 20)
  (check-equal? (window-height (frame-active-window fr1)) 5)

  ;; 分屏后点击右窗口 → focus + point 相对偏移
  (define-values (fs _s1 _s2) (framework-handle cfg fm (key-event #\B (modifiers #t #f #f #f))))
  (define-values (fs2 _s3 _s4) (framework-handle cfg fs (mouse-press-event 'left 7 0 (modifiers #f #f #f #f))))
  (check-equal? (frame-active fs2) 1)
  (check-equal? (window-point (frame-active-window fs2)) (cursor 0 1))

  (displayln "commands.rkt: all tests passed"))
