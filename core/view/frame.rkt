#lang racket

(require racket/list
         "../text/cursor.rkt" "../text/buffer.rkt" "../text/content.rkt"
         "../text/patch.rkt"
         "window.rkt" "view.rkt" "paint.rkt" rackunit)

;;; frame.rkt —— 多窗口视口机制（窗口集合 + linked 同步，布局无关）
;;;
;;; frame = 一组 window + 焦点 + 不透明 layout 数据 + 尺寸。
;;;   - layout 字段：布局策略的私有状态，由 layout 插件解释，core 不碰。
;;;   - 本层只做机制：窗口增删、linked-buffer 同步、逐窗口渲染、光标跟随、焦点循环。
;;;   - 布局几何（rects/order）与 split/close 由 layout 插件提供（见 framework/reference）。

(provide
 (struct-out frame)
 frame-open
 frame-window
 frame-active-window
 frame-window-count
 frame-set-window
 frame-set-active
 frame-add-window
 frame-remove-window
 frame-resize
 frame-edit-active
 frame-sync-buffer
 frame-replace-buffer
 frame-ensure-active
 frame-cycle-active
 frame-sync-sizes
 frame-pieces)

(struct frame
  (windows        ; (hashof window-id window)
   active         ; window-id | #f
   layout         ; any  布局私有状态（layout 插件解释）
   rows cols      ; buffer 区尺寸
   next-window-id ; nat
   )
  #:transparent)

;;; ---------- 构造 ----------

(define (frame-open b [rows 24] [cols 80])
  (frame (hash 0 (window-open b rows cols)) 0 #f
         (max 1 rows) (max 1 cols) 1))

;;; ---------- 投影 ----------

(define (frame-window f id) (hash-ref (frame-windows f) id #f))
(define (frame-active-window f)
  (and (frame-active f) (frame-window f (frame-active f))))
(define (frame-window-count f) (hash-count (frame-windows f)))

;;; ---------- 基础更新 ----------

(define (frame-set-window f id w)
  (struct-copy frame f [windows (hash-set (frame-windows f) id w)]))

(define (frame-set-active f id)
  (struct-copy frame f [active id]))

(define (frame-resize f rows cols)
  (struct-copy frame f [rows (max 1 rows)] [cols (max 1 cols)]))

;;; ---------- 窗口集合管理（布局无关） ----------

;; 新增一个窗口，默认共享 active 的 buffer（eq? 同一 struct），
;; 并从 active 的 point 开始（分屏看到同一位置）。
(define (frame-add-window f [buffer #f])
  (define id (frame-next-window-id f))
  (define src (frame-active-window f))
  (define b (or buffer (window-buffer src)))
  (define w (window-set-point (window-open b (frame-rows f) (frame-cols f))
                              (window-point src)))
  (values (struct-copy frame f
            [windows (hash-set (frame-windows f) id w)]
            [next-window-id (add1 id)])
          id))

;; 删除窗口（至少留一个）；若删的是 active，回退到任一剩余窗口。
(define (frame-remove-window f id)
  (cond
    [(<= (frame-window-count f) 1) f]
    [else
     (define windows* (hash-remove (frame-windows f) id))
     (struct-copy frame f
       [windows windows*]
       [active (if (= id (frame-active f))
                   (car (hash-keys windows*))
                   (frame-active f))])]))

;;; ---------- 编辑：linked-buffer 同步 ----------

;; 在窗口 id 上执行 edit-fn（window → (values window desc)），只更新该窗口。
(define (frame-edit-active f id edit-fn)
  (define w (frame-window f id))
  (define-values (w1 desc) (edit-fn w))
  (values (frame-set-window f id w1) desc))

;; 把 id 的 buffer 换成 new-b，并把所有「共享 old-b」的窗口一起换 + 映射 point。
(define (frame-sync-buffer f id old-b new-b desc)
  (struct-copy frame f
    [windows
     (for/hash ([(wid pw) (in-hash (frame-windows f))])
       (cond
         [(= wid id) (values wid (window-set-buffer pw new-b))]
         [(eq? (window-buffer pw) old-b) (values wid (window-rebase pw new-b desc))]
         [else (values wid pw)]))]))

;; 让一个共享 old-b 的窗口「换底」到 new-b：point 按 edit-desc 映射到编辑后位置，
;; 若原 point 落在被替换区间内则落到区间起点。
(define (window-rebase w new-b desc)
  (define p (window-point w))
  (define p* (or (edit-desc-map-position desc (cursor-line p) (cursor-col p))
                 (cursor (edit-desc-s-line desc) (edit-desc-s-col desc))))
  (window-set-point (struct-copy window w [buffer new-b]) p*))

;; 把所有「内容与 base-b 相同」的窗口 buffer 换成 new-b（内容不变 → point 不变）。
;; 用于异步插件结果/标注的延后应用；内容已变（stale）时没有窗口匹配 → 自然 no-op。
(define (frame-replace-buffer f base-b new-b)
  (struct-copy frame f
    [windows
     (for/hash ([(id w) (in-hash (frame-windows f))])
       (values id
               (if (buffer-content-same? (window-buffer w) base-b)
                   (window-set-buffer w new-b)
                   w)))]))

;; 光标跟随：让 active 窗口的 point 可见
(define (frame-ensure-active f)
  (define id (frame-active f))
  (define w (frame-active-window f))
  (if (not w)
      f
      (frame-set-window f id (window-ensure-point w))))

;;; ---------- 焦点 ----------

;; 按给定顺序列表循环焦点（顺序由 layout 插件的 order 提供）
(define (frame-cycle-active f order dir)
  (define id (frame-active f))
  (define n (length order))
  (define idx (index-of order id))
  (define new-id
    (cond [(not idx) (car order)]
          [(eq? dir 'next) (list-ref order (modulo (add1 idx) n))]
          [(eq? dir 'prev) (list-ref order (modulo (sub1 idx) n))]
          [else id]))
  (frame-set-active f new-id))

;;; ---------- 渲染 ----------

;; 把每个 window 的尺寸同步到给定 rects（layout 插件在 split/close/resize 后调用，
;; 保证 frame-ensure-active 用正确尺寸）。
(define (frame-sync-sizes f rects)
  (struct-copy frame f
    [windows
     (for/hash ([r (in-list rects)])
       (match-define (list id _x _y w h) r)
       (values id (window-set-size (frame-window f id) h w)))]))

;; rects = (listof (window-id x y w h)) → pieces = (listof (window-id x y w h screen))
(define (frame-pieces f rects)
  (for/list ([r (in-list rects)])
    (match-define (list id x y rw rh) r)
    (define w (window-set-size (frame-window f id) rh rw))
    (list id x y rw rh (paint w))))

;;; ---------- 测试 ----------

(module+ test
  (require "screen.rkt")
  (define b (buffer-open "hello\nworld"))
  (define f0 (frame-open b 3 10))

  ;; 基本
  (check-equal? (frame-window-count f0) 1)
  (check-equal? (frame-active f0) 0)

  ;; add-window：共享 buffer、分配 id、point 同 active
  (define-values (f1 id1) (frame-add-window f0))
  (check-equal? id1 1)
  (check-equal? (frame-window-count f1) 2)
  (check-true (eq? (window-buffer (frame-window f1 0)) (window-buffer (frame-window f1 1))))
  (check-equal? (window-point (frame-window f1 1)) (window-point (frame-window f1 0)))

  ;; remove-window（至少留一个）
  (define f2 (frame-remove-window f1 1))
  (check-equal? (frame-window-count f2) 1)
  (check-equal? (frame-active f2) 0)
  (check-equal? (frame-window-count (frame-remove-window f2 0)) 1)

  ;; linked 同步
  (define id (frame-active f1))
  (define old-b (window-buffer (frame-window f1 id)))
  (define-values (fe desc) (frame-edit-active f1 id (lambda (w) (window-insert w #\X))))
  (define fs (frame-sync-buffer fe id old-b (window-buffer (frame-window fe id)) desc))
  (check-equal? (buffer->string (window-buffer (frame-window fs 0))) "Xhello\nworld")
  (check-equal? (buffer->string (window-buffer (frame-window fs 1))) "Xhello\nworld")
  (check-true (eq? (window-buffer (frame-window fs 0)) (window-buffer (frame-window fs 1))))

  ;; cycle-active
  (check-equal? (frame-active (frame-cycle-active f1 '(0 1) 'next)) 1)

  ;; frame-replace-buffer：内容相同的窗口换 buffer（异步标注应用）；stale 时 no-op
  (define b-ann (buffer-put-text-property b 0 0 1 'face 'bold))
  (define fr (frame-replace-buffer f1 b b-ann))
  (check-true (eq? (window-buffer (frame-window fr 0)) b-ann))
  (check-true (eq? (window-buffer (frame-window fr 1)) b-ann))
  (define b-other (buffer-open "different"))
  (check-equal? (frame-replace-buffer f1 b-other b-ann) f1)   ; 内容不匹配 → 原样

  ;; sync-sizes + pieces
  (define rects (list (list 0 0 0 5 3) (list 1 5 0 5 3)))
  (define f5 (frame-sync-sizes f1 rects))
  (check-equal? (window-width (frame-window f5 0)) 5)
  (check-equal? (window-width (frame-window f5 1)) 5)
  (define pieces (frame-pieces f5 rects))
  (check-equal? (length pieces) 2)
  (check-equal? (cadddr (car pieces)) 5)
  (check-equal? (screen-cols (list-ref (car pieces) 5)) 5)

  (displayln "frame.rkt: all tests passed"))
