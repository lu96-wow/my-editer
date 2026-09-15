#lang racket

(require racket/list
         "../text/cursor.rkt" "../text/buffer.rkt" "../text/content.rkt"
         "window.rkt" "view.rkt" "screen.rkt" "paint.rkt" rackunit)

;;; frame.rkt —— 多窗口视口（机制，后端无关）
;;;
;;; frame = 一组 window + 布局树 + 焦点。buffer 与 window 的关系不变：
;;;   - buffer 无光标，可被多个 window 共享；
;;;   - 共享 = 两个 window 的 (window-buffer w) eq?（同一个 struct）。
;;;
;;; 本层只做机制：布局几何、焦点路由、linked-buffer 同步、拼帧。
;;; 不含 keymap / 插件 / 退出标志——那些在 logic/event.rkt 的组合层。

(provide
 (struct-out frame)
 (struct-out frame-leaf)
 (struct-out frame-vsplit)
 (struct-out frame-hsplit)
 frame-open
 frame-window
 frame-active-window
 frame-window-count
 frame-leaf-order
 frame-layout-rects
 frame-window-rect
 frame-window-at
 frame-normalize
 frame-resize
 frame-split
 frame-close
 frame-focus
 frame-edit-active
 frame-sync-buffer
 frame-ensure-active
 frame-paint)

;;; ---------- 结构 ----------

;; 布局树：叶子 = window-id；内部节点 = 分割
(struct frame-leaf   (window-id)           #:transparent)
(struct frame-vsplit (top bottom ratio)    #:transparent)  ; 上下分，ratio 给 top
(struct frame-hsplit (left right ratio)    #:transparent)  ; 左右分，ratio 给 left

(struct frame
  (windows        ; (hashof window-id window)
   layout         ; frame-leaf / frame-vsplit / frame-hsplit
   active         ; window-id | #f
   rows cols      ; buffer 区尺寸
   next-window-id ; nat
   )
  #:transparent)

;;; ---------- 构造 ----------

(define (frame-open b [rows 24] [cols 80])
  (frame (hash 0 (window-open b rows cols)) (frame-leaf 0) 0
         (max 1 rows) (max 1 cols) 1))

;;; ---------- 投影 ----------

(define (frame-window f id) (hash-ref (frame-windows f) id #f))
(define (frame-active-window f)
  (and (frame-active f) (frame-window f (frame-active f))))
(define (frame-window-count f) (hash-count (frame-windows f)))

;; 布局树的前序叶子 = 焦点/绘制顺序
(define (frame-leaf-order f) (leaf-order (frame-layout f)))

(define (leaf-order tree)
  (cond
    [(frame-leaf? tree) (list (frame-leaf-window-id tree))]
    [(frame-vsplit? tree) (append (leaf-order (frame-vsplit-top tree))
                                  (leaf-order (frame-vsplit-bottom tree)))]
    [(frame-hsplit? tree) (append (leaf-order (frame-hsplit-left tree))
                                  (leaf-order (frame-hsplit-right tree)))]
    [else (error 'leaf-order "bad layout ~a" tree)]))

;;; ---------- 布局：树 → 矩形 ----------

(define (frame-layout-rects f)
  (let loop ([tree (frame-layout f)] [x 0] [y 0]
             [w (frame-cols f)] [h (frame-rows f)])
    (cond
      [(frame-leaf? tree) (list (list (frame-leaf-window-id tree) x y w h))]
      [(frame-vsplit? tree)
       (define th (clamp-dir h (frame-vsplit-ratio tree)))
       (append (loop (frame-vsplit-top tree) x y w th)
               (loop (frame-vsplit-bottom tree) x (+ y th) w (- h th)))]
      [(frame-hsplit? tree)
       (define lw (clamp-dir w (frame-hsplit-ratio tree)))
       (append (loop (frame-hsplit-left tree) x y lw h)
               (loop (frame-hsplit-right tree) (+ x lw) y (- w lw) h))]
      [else (error 'frame-layout-rects "bad layout ~a" tree)])))

(define (clamp-dir total ratio)
  (max 1 (min (- total 1) (floor (* total ratio)))))

;; 把每个 window 的尺寸同步到布局矩形（供 ensure-point / 编辑用正确尺寸）
(define (frame-normalize f)
  (struct-copy frame f
    [windows
     (for/hash ([r (in-list (frame-layout-rects f))])
       (match-define (list id _x _y w h) r)
       (values id (window-set-size (frame-window f id) h w)))]))

(define (frame-window-rect f id)
  (for/first ([r (in-list (frame-layout-rects f))]
              #:when (= (car r) id))
    r))

(define (frame-window-at f x y)
  (for/or ([r (in-list (frame-layout-rects f))])
    (match-define (list id rx ry rw rh) r)
    (and (<= rx x (+ rx rw -1)) (<= ry y (+ ry rh -1)) id)))

;;; ---------- 窗口管理 ----------

(define (frame-resize f rows cols)
  (frame-normalize (struct-copy frame f [rows (max 1 rows)] [cols (max 1 cols)])))

;; 把 active 一分为二。dir ∈ 'vsplit(上下) 'hsplit(左右)；新窗口共享同一 buffer，focus 到新窗口。
(define (frame-split f dir)
  (define id (frame-active f))
  (define w (frame-window f id))
  (define nid (frame-next-window-id f))
  (define w2 (window-open (window-buffer w) (window-height w) (window-width w)))
  (define node
    (case dir
      [(vsplit) (frame-vsplit (frame-leaf id) (frame-leaf nid) 1/2)]
      [(hsplit) (frame-hsplit (frame-leaf id) (frame-leaf nid) 1/2)]
      [else (error 'frame-split "unknown dir ~a" dir)]))
  (frame-normalize
   (struct-copy frame f
     [windows (hash-set (frame-windows f) nid w2)]
     [layout (tree-replace (frame-layout f) id node)]
     [active nid]
     [next-window-id (add1 nid)])))

;; 关 active（至少留一个）；父节点塌缩成兄弟。
(define (frame-close f)
  (define id (frame-active f))
  (cond
    [(<= (frame-window-count f) 1) f]
    [else
     (define layout* (tree-remove (frame-layout f) id))
     (define windows* (hash-remove (frame-windows f) id))
     (define order (leaf-order layout*))
     (frame-normalize
      (struct-copy frame f
        [windows windows*]
        [layout layout*]
        [active (car order)]))]))

(define (frame-focus f dir)
  (define order (frame-leaf-order f))
  (define id (frame-active f))
  (define n (length order))
  (define idx (index-of order id))
  (define new-id
    (cond [(not idx) (car order)]
          [(eq? dir 'next) (list-ref order (modulo (add1 idx) n))]
          [(eq? dir 'prev) (list-ref order (modulo (sub1 idx) n))]
          [else id]))
  (struct-copy frame f [active new-id]))

;;; ---------- 编辑：linked-buffer 同步 ----------

;; 在窗口 id 上执行 edit-fn（window → (values window desc)），只更新该窗口。
(define (frame-edit-active f id edit-fn)
  (define w (frame-window f id))
  (define-values (w1 desc) (edit-fn w))
  (values (struct-copy frame f [windows (hash-set (frame-windows f) id w1)]) desc))

;; 把 id 的 buffer 换成 new-b，并把所有「共享 old-b」的窗口一起换 + 映射 point。
;; old-b = 编辑前 active 的 buffer；共享窗口的 point 按 edit-desc 跟随（落在删除区间 → 移到编辑起点）。
(define (frame-sync-buffer f id old-b new-b desc)
  (struct-copy frame f
    [windows
     (for/hash ([(wid pw) (in-hash (frame-windows f))])
       (cond
         [(= wid id) (values wid (window-set-buffer pw new-b))]
         [(eq? (window-buffer pw) old-b) (values wid (window-sync-buffer pw new-b desc))]
         [else (values wid pw)]))]))

(define (window-sync-buffer w new-b desc)
  (define p (window-point w))
  (define p* (or (edit-desc-map-position desc (cursor-line p) (cursor-col p))
                 (cursor (edit-desc-s-line desc) (edit-desc-s-col desc))))
  (window-set-point (struct-copy window w [buffer new-b]) p*))

;; 光标跟随：让 active 窗口的 point 可见
(define (frame-ensure-active f)
  (define id (frame-active f))
  (define w (frame-active-window f))
  (if (not w)
      f
      (struct-copy frame f
        [windows (hash-set (frame-windows f) id (window-ensure-point w))])))

;;; ---------- 拼帧 ----------

(define (frame-paint f)
  (define pieces
    (for/list ([r (in-list (frame-layout-rects f))])
      (match-define (list id x y rw rh) r)
      (define w (window-set-size (frame-window f id) rh rw))
      (list id x y (paint w))))
  (screen-compose (frame-rows f) (frame-cols f) pieces (frame-active f)))

;;; ---------- 树操作 ----------

(define (tree-replace tree id new)
  (cond
    [(frame-leaf? tree) (if (= id (frame-leaf-window-id tree)) new tree)]
    [(frame-vsplit? tree)
     (frame-vsplit (tree-replace (frame-vsplit-top tree) id new)
                   (tree-replace (frame-vsplit-bottom tree) id new)
                   (frame-vsplit-ratio tree))]
    [(frame-hsplit? tree)
     (frame-hsplit (tree-replace (frame-hsplit-left tree) id new)
                   (tree-replace (frame-hsplit-right tree) id new)
                   (frame-hsplit-ratio tree))]
    [else (error 'tree-replace "bad layout ~a" tree)]))

(define (tree-remove tree id)
  (cond
    [(frame-leaf? tree) (if (= id (frame-leaf-window-id tree)) #f tree)]
    [(frame-vsplit? tree)
     (define t* (tree-remove (frame-vsplit-top tree) id))
     (define b* (tree-remove (frame-vsplit-bottom tree) id))
     (cond [(not t*) b*] [(not b*) t*]
           [else (frame-vsplit t* b* (frame-vsplit-ratio tree))])]
    [(frame-hsplit? tree)
     (define l* (tree-remove (frame-hsplit-left tree) id))
     (define r* (tree-remove (frame-hsplit-right tree) id))
     (cond [(not l*) r*] [(not r*) l*]
           [else (frame-hsplit l* r* (frame-hsplit-ratio tree))])]
    [else (error 'tree-remove "bad layout ~a" tree)]))

;;; ---------- 测试 ----------

(module+ test
  (define b (buffer-open "hello\nworld"))
  (define f0 (frame-open b 3 10))

  ;; 基本
  (check-equal? (frame-window-count f0) 1)
  (check-equal? (frame-active f0) 0)
  (check-equal? (frame-window f0 0) (window-open b 3 10))

  ;; split：共享 buffer（eq?），focus 到新窗口
  (define f1 (frame-split f0 'hsplit))
  (check-equal? (frame-window-count f1) 2)
  (check-equal? (frame-active f1) 1)
  (check-true (eq? (window-buffer (frame-window f1 0))
                   (window-buffer (frame-window f1 1))))
  (check-equal? (frame-layout-rects (frame-resize f1 4 10))
                (list (list 0 0 0 5 4) (list 1 5 0 5 4)))

  ;; vsplit：上下各半
  (define f1v (frame-split f0 'vsplit))
  (check-equal? (frame-layout-rects (frame-resize f1v 4 10))
                (list (list 0 0 0 10 2) (list 1 0 2 10 2)))

  ;; linked 同步：在 active 编辑，共享窗口 buffer/point 跟着变
  (define fb (frame-split (frame-open (buffer-open "ab") 3 10) 'hsplit))
  (define id (frame-active fb))          ; 1
  (define old-b (window-buffer (frame-window fb id)))   ; "ab"
  (define-values (fe desc) (frame-edit-active fb id (lambda (w) (window-insert w #\X))))
  (define fs (frame-sync-buffer fe id old-b (window-buffer (frame-window fe id)) desc))
  (check-equal? (buffer->string (window-buffer (frame-window fs 0))) "Xab")
  (check-equal? (buffer->string (window-buffer (frame-window fs 1))) "Xab")
  (check-true (eq? (window-buffer (frame-window fs 0))
                   (window-buffer (frame-window fs 1))))
  (check-equal? (window-point (frame-window fs 0)) (cursor 0 0))   ; 在插入点 → 不动
  (check-equal? (window-point (frame-window fs 1)) (cursor 0 1))   ; active 前进

  ;; 共享窗口 point 在插入点之后 → 右移
  (define fb2 (frame-split (frame-open (buffer-open "ab") 3 10) 'hsplit))
  (define fb2a (struct-copy frame fb2
                 [windows (hash-set (frame-windows fb2) 0
                                    (window-set-point (frame-window fb2 0) (cursor 0 1)))]))
  (define id2 (frame-active fb2a))
  (define old-b2 (window-buffer (frame-window fb2a id2)))
  (define-values (fe2 desc2) (frame-edit-active fb2a id2 (lambda (w) (window-insert w #\X))))
  (define fs2 (frame-sync-buffer fe2 id2 old-b2 (window-buffer (frame-window fe2 id2)) desc2))
  (check-equal? (window-point (frame-window fs2 0)) (cursor 0 2))

  ;; close：关 active(1)，塌缩回窗口 0
  (define f3 (frame-close f1))
  (check-equal? (frame-window-count f3) 1)
  (check-equal? (frame-active f3) 0)
  ;; 只剩一个时拒绝关
  (check-equal? (frame-window-count (frame-close f3)) 1)

  ;; focus 循环
  (check-equal? (frame-active (frame-focus f1 'next)) 0)
  (check-equal? (frame-active (frame-focus (frame-focus f1 'next) 'prev)) 1)

  ;; 拼帧：左右两屏，active 光标在右侧偏移
  (define fp (frame-paint (frame-resize f1 2 10)))
  (check-equal? (screen-rows fp) 2)
  (check-equal? (screen-cols fp) 10)
  (check-equal? (vector-ref (screen-row-runs fp) 0)
                (list (run 0 "hello" (hash)) (run 5 "hello" (hash))))
  (check-equal? (screen-cursor-row fp) 0)
  (check-equal? (screen-cursor-col fp) 5)

  (displayln "frame.rkt: all tests passed"))
