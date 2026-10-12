#lang racket

;;; edit4-test/edit3-parity.rkt —— 能力验证：edit3 的布局能被 edit4 等价表示
;;;
;;; 做法：把 edit3 的 tiling 树**逐节点转换**成 edit4 的树
;;;   item(basis,grow,shrink,min) → child(size basis (positive? grow))
;;;   tile(wid,vid,min)           → leaf(wid,min)
;;; 然后分别用两边求解器布局，逐窗比较矩形（跨结构类型，比 x/y/w/h 数值）。

(require rackunit
         racket/list
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         (prefix-in e3: "../edit3/core/layout.rkt")
         (prefix-in e3: "../edit3/core/state.rkt")
         (prefix-in e3: "../edit3/core/event.rkt")
         (prefix-in e3: "../edit3/core/interaction.rkt"))

(define (conv t)
  (cond
    [(e3:tile? t) (leaf (e3:tile-wid t) (e3:tile-min t))]
    [else
     (split (e3:split-axis t) 1
            (for/list ([it (in-list (e3:split-items t))])
              (child (size (e3:item-basis it) (positive? (e3:item-grow it)))
                     (conv (e3:item-child it)))))]))
(define (conv-tl e3tl) (conv (e3:tiling-root e3tl)))

(define (e3r r) (list (e3:rect-x r) (e3:rect-y r) (e3:rect-w r) (e3:rect-h r)))
(define (e4r r) (list (rect-x r) (rect-y r) (rect-w r) (rect-h r)))

(define (e3-rects e3tl size)
  (for/hash ([p (in-list (e3:geometry-placements (e3:layout e3tl '() size)))])
    (values (e3:placement-wid p) (e3r (e3:placement-rect p)))))
(define (e4-rects tree size)
  (for/hash ([(k v) (in-hash (geometry-rects (layout tree (rect 0 0 (car size) (cdr size)))))])
    (values k (e4r v))))

(define (id-sort ks) (sort ks (lambda (x y) (string<? (format "~a" x) (format "~a" y)))))
(define (compare! tag e3tl tree size)
  (define a (e3-rects e3tl size))
  (define b (e4-rects tree size))
  (check-equal? (id-sort (hash-keys a)) (id-sort (hash-keys b)) (format "~a: 窗口集合" tag))
  (for ([(k v) (in-hash a)])
    (check-equal? (hash-ref b k #f) v (format "~a: wid ~a" tag k))))

;;; ---------- 1. edit3 启动底盘 ----------

(define (tile* w) (e3:tile w w (cons 2 2) 'b))
(define (panel* w) (e3:tile w w (cons 1 1) 'b))

(define e3-boot
  (e3:tiling
   (e3:split 'h
             (list (e3:item 28 0 0 1 (panel* 2))
                   (e3:item 1 1 1 2
                             (e3:split 'v
                                       (list (e3:item 1 1 1 2 (tile* 0))
                                             (e3:item 1 0 0 1 (panel* 1)))))))))
(compare! "boot 80x24" e3-boot (conv-tl e3-boot) (cons 80 24))
(compare! "boot 100x30" e3-boot (conv-tl e3-boot) (cons 100 30))
(compare! "boot 60x18" e3-boot (conv-tl e3-boot) (cons 60 18))

;;; ---------- 2. 隐藏侧栏（区域）：摘掉 wid 2，容器收拢 ----------

(define e3-hid (e3:layout-remove-wid e3-boot 2))
(define e4-hid (remove-leaf (conv-tl e3-boot) 2))
(compare! "hide sidebar" e3-hid e4-hid (cons 80 24))

;;; ---------- 3. 分裂编辑窗（h，新窗在后） ----------

(define e3-sp (e3:layout-split-tile e3-boot 0 'h (tile* 9) #f))
(define e4-sp (split-leaf (conv-tl e3-boot) 0 'h 'after (leaf 9 (cons 2 2))))
(compare! "split editor h" e3-sp e4-sp (cons 80 24))

;;; ---------- 4. 嵌套 2×2 ----------

(define e3-2x2
  (e3:tiling
   (e3:split 'h
             (list (e3:item 1 1 1 2 (e3:split 'v (list (e3:item 1 1 1 2 (tile* 'a))
                                                       (e3:item 1 1 1 2 (tile* 'b)))))
                   (e3:item 1 1 1 2 (e3:split 'v (list (e3:item 1 1 1 2 (tile* 'c))
                                                       (e3:item 1 1 1 2 (tile* 'd)))))))))
(compare! "2x2" e3-2x2 (conv-tl e3-2x2) (cons 21 11))

;;; ---------- 5. 三列（固定 + 弹性混合） ----------

(define e3-3col
  (e3:tiling
   (e3:split 'h (list (e3:item 20 0 0 1 (tile* 'L))
                      (e3:item 1 1 1 2 (tile* 'M))
                      (e3:item 10 0 0 1 (tile* 'R))))))
(compare! "3col fixed/elastic" e3-3col (conv-tl e3-3col) (cons 80 24))

;;; ---------- 6. 贴边插区域（add-side） ----------

(define e3-side (e3:layout-add-side e3-boot (panel* 'log) 'right 24))
(define e4-side (insert-side (conv-tl e3-boot) 'right (size 24 #f) (leaf 'log (cons 1 1))))
(compare! "add region right" e3-side e4-side (cons 80 24))

;;; ---------- 7. 浮窗 ----------

(define (e3-frect e3tl floats wid size)
  (define g (e3:layout e3tl floats size))
  (define p (findf (lambda (x) (eqv? wid (e3:placement-wid x))) (e3:geometry-placements g)))
  (and p (e3r (e3:placement-rect p))))
(define (e4-frect tree floats wid size)
  (define-values (_c f) (ensure-layout empty-layout-cache tree floats size))
  (define r (frame-float-rect f wid))
  (and r (e4r r)))

;; 钠 screen 右下
(define e3fl (list (e3:float 'F 'F (e3:anchor 'screen 'right 'bottom 2 2) (cons 46 10) 'b)))
(check-equal? (e3-frect e3-boot e3fl 'F (cons 80 24))
              (e4-frect (conv-tl e3-boot)
                        (list (float 'F (anchor 'screen 'right 'bottom 2 2) (cons 46 10)))
                        'F (cons 80 24)))
;; 钠到 pane（rel = wid）
(define e3fp (list (e3:float 'P 'P (e3:anchor 0 'left 'top 1 1) (cons 6 3) 'b)))
(check-equal? (e3-frect e3-boot e3fp 'P (cons 80 24))
              (e4-frect (conv-tl e3-boot)
                        (list (float 'P (anchor 0 'left 'top 1 1) (cons 6 3)))
                        'P (cons 80 24)))

;;; ---------- 8. 拖拽行为对照（拖侧栏缝） ----------

(define esz (cons 80 24))
(define (ev->ctx w ev)
  (define-values (_c f) (ensure-layout empty-layout-cache (world-layout w) (world-floats w) esz))
  (ctx ev esz f))

(define e3st0 (e3:make-state #:tiling e3-boot))
(define e3g0 (e3:layout e3-boot '() esz))
(define e3st1 (e3:pointer-press e3g0 e3st0 (e3:cursor-event 'press 'left 28 5)))
(define e3st2 (e3:pointer-move e3g0 e3st1 (e3:cursor-event 'move 'left 35 5)))
(define e3-drag (e3-rects (e3:state-tiling e3st2) esz))

(define (run1 w ev)
  (car (call-with-values
        (lambda () (dispatch base-commands base-scopes base-keymap (ev->ctx w ev) w))
        list)))
(define w0 (make-world #:layout (conv-tl e3-boot) #:focus 0))
(define w1 (run1 w0 (cursor-event 'press 'left 28 5)))
(define w2 (run1 w1 (cursor-event 'move 'left 35 5)))
(define e4-drag (e4-rects (world-layout w2) esz))

(check-equal? (hash-ref e4-drag 2) (hash-ref e3-drag 2) "拖拽后侧栏宽度")
(check-equal? (hash-ref e4-drag 0) (hash-ref e3-drag 0) "拖拽后编辑区")
(check-equal? (hash-ref e4-drag 1) (hash-ref e3-drag 1) "拖拽后状态栏")

(displayln "edit4/edit3-parity.rkt: all tests passed")
