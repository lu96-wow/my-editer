#lang racket

;;; edit2/layout.rkt —— 纯布局函数（wid / vid 分离）
;;;
;;;   layout : LayoutTree Size -> [Placement]     （size = (cons w h)）
;;;
;;; 窗口（pane / float）有自己的身份 **wid**，并引用一个视图 **vid**。
;;; 于是同一个 vid 可以出现在多个 wid（同 view 多位置）；焦点、浮窗栈、命中都用 wid。
;;; split 的每段尺寸 = 固定格数（整数）或 'flex（均分剩余）。
;;; 浮窗最后放置、clamp 进屏幕、z 更高。只吃数字，可脱离编辑器单测。

(provide
 (struct-out rect)
 (struct-out placement)
 layout
 ;; 命中定位
 layout-hit rect-contains? rect-local
 ;; 查询
 layout-wids layout-vids layout-has-wid? layout-has? layout-wid-vid layout-wid-of-vid
 layout-fresh-wid
 ;; 布局树手术（纯）
 layout-remove-wid layout-remove-vid layout-replace-wid-node layout-set-pane-vid
 layout-split-wid
 layout-add-side layout-add-bottom layout-add-float layout-add-main
 layout-has-empty? layout-fill-empty
 parse-layout)

(require "state.rkt")

(struct rect (x y w h) #:transparent)
;; wid = 窗口身份；vid = 该窗口显示的视图。浮窗同样有 wid / vid。
(struct placement (wid vid rect z float?) #:transparent)

(define (clamp v lo hi) (max lo (min hi v)))

;;; ---------- 配置数据 → Layout ----------
;;; 数据形态：
;;;   (pane id) (main node) (blank) (empty-area)
;;;   (split axis ((size node) ...))
;;; resolve : id -> (cons wid vid)
(define (parse-layout d resolve)
  (cond
    [(and (pair? d) (eq? (car d) 'pane))
     (define r (resolve (cadr d)))
     (pane (car r) (cdr r))]
    [(and (pair? d) (eq? (car d) 'main)) (main (parse-layout (cadr d) resolve))]
    [(and (pair? d) (eq? (car d) 'blank)) (blank)]
    [(and (pair? d) (eq? (car d) 'empty-area)) (empty-area)]
    [(and (pair? d) (eq? (car d) 'split))
     (split (cadr d) (for/list ([p (in-list (caddr d))])
                       (cons (car p) (parse-layout (cadr p) resolve))))]
    [else (blank)]))

;;; ---------- 命中定位（屏幕坐标 → 窗口 + 窗口内坐标） ----------

(define (rect-contains? r x y)
  (and (<= (rect-x r) x) (< x (+ (rect-x r) (rect-w r)))
       (<= (rect-y r) y) (< y (+ (rect-y r) (rect-h r)))))

;; 最上层（z 最大）包含 (x,y) 的 placement；无 → #f。
(define (layout-hit placements x y)
  (for/fold ([best #f]) ([p (in-list placements)]
                         #:when (rect-contains? (placement-rect p) x y))
    (if (or (not best) (> (placement-z p) (placement-z best))) p best)))

;; placement + 屏幕点 → (values wid 窗口内列 窗口内行)。
(define (rect-local p x y)
  (define r (placement-rect p))
  (values (placement-wid p) (- x (rect-x r)) (- y (rect-y r))))

;;; ---------- 查询 ----------

(define (layout-wids tree)
  (cond
    [(pane? tree) (list (pane-wid tree))]
    [(float? tree) (list (float-wid tree))]
    [(main? tree) (layout-wids (main-tree tree))]
    [(split? tree) (append* (for/list ([p (in-list (split-parts tree))]) (layout-wids (cdr p))))]
    [else '()]))

(define (layout-vids tree)
  (cond
    [(pane? tree) (if (pane-vid tree) (list (pane-vid tree)) '())]
    [(float? tree) (if (float-vid tree) (list (float-vid tree)) '())]
    [(main? tree) (layout-vids (main-tree tree))]
    [(split? tree) (append* (for/list ([p (in-list (split-parts tree))]) (layout-vids (cdr p))))]
    [else '()]))

(define (layout-has-wid? tree wid) (and (memv wid (layout-wids tree)) #t))
(define (layout-has? tree vid) (and (memv vid (layout-vids tree)) #t))

;; 某 wid 显示哪个 vid（不在 → #f）。
(define (layout-wid-vid tree wid)
  (cond
    [(pane? tree) (and (eqv? wid (pane-wid tree)) (pane-vid tree))]
    [(float? tree) (and (eqv? wid (float-wid tree)) (float-vid tree))]
    [(main? tree) (layout-wid-vid (main-tree tree) wid)]
    [(split? tree) (for/or ([p (in-list (split-parts tree))]) (layout-wid-vid (cdr p) wid))]
    [else #f]))

;; 显示某 vid 的第一个 wid（不在 → #f）。
(define (layout-wid-of-vid tree vid)
  (for/first ([w (in-list (layout-wids tree))]
              #:when (eqv? vid (layout-wid-vid tree w)))
    w))

;; 分配一个新 wid：现有最大整 wid + 1（关闭后的 wid 可复用，引用已同步清理）。
(define (layout-fresh-wid tree)
  (add1 (for/fold ([m -1]) ([w (in-list (layout-wids tree))])
          (if (number? w) (max m w) m))))

(define (layout-has-empty? tree)
  (cond
    [(empty-area? tree) #t]
    [(main? tree) (layout-has-empty? (main-tree tree))]
    [(split? tree) (for/or ([p (in-list (split-parts tree))]) (layout-has-empty? (cdr p)))]
    [else #f]))

;; 把第一个持久空位换成 node（没有则原样返回）。
(define (layout-fill-empty tree node)
  (cond
    [(empty-area? tree) node]
    [(main? tree) (main (layout-fill-empty (main-tree tree) node))]
    [(split? tree) (split (split-axis tree)
                          (for/list ([p (in-list (split-parts tree))])
                            (cons (car p) (layout-fill-empty (cdr p) node))))]
    [else tree]))

;;; ---------- 布局树手术（纯） ----------

;; 按 wid 删窗口；split 只剩一项就收拢。
(define (layout-remove-wid tree wid)
  (cond
    [(pane? tree)  (if (eqv? wid (pane-wid tree)) (blank) tree)]
    [(float? tree) (if (eqv? wid (float-wid tree)) (blank) tree)]
    [(main? tree)  (main (layout-remove-wid (main-tree tree) wid))]
    [(split? tree)
     (define ps (for/list ([p (in-list (split-parts tree))])
                  (cons (car p) (layout-remove-wid (cdr p) wid))))
     (define kept (filter (lambda (p) (not (blank? (cdr p)))) ps))
     (cond [(null? kept) (blank)]
           [(null? (cdr kept)) (cdr (car kept))]
           [else (split (split-axis tree) kept)])]
    [else tree]))

;; 删所有显示该 vid 的窗口（同 view 多位置 → 一次全清）。
(define (layout-remove-vid tree vid)
  (cond
    [(pane? tree)  (if (eqv? vid (pane-vid tree)) (blank) tree)]
    [(float? tree) (if (eqv? vid (float-vid tree)) (blank) tree)]
    [(main? tree)  (main (layout-remove-vid (main-tree tree) vid))]
    [(split? tree)
     (define ps (for/list ([p (in-list (split-parts tree))])
                  (cons (car p) (layout-remove-vid (cdr p) vid))))
     (define kept (filter (lambda (p) (not (blank? (cdr p)))) ps))
     (cond [(null? kept) (blank)]
           [(null? (cdr kept)) (cdr (car kept))]
           [else (split (split-axis tree) kept)])]
    [else tree]))

(define (layout-replace-wid-node tree wid new-node)
  (cond
    [(pane? tree)  (if (eqv? wid (pane-wid tree)) new-node tree)]
    [(float? tree) (if (eqv? wid (float-wid tree)) new-node tree)]
    [(main? tree)  (main (layout-replace-wid-node (main-tree tree) wid new-node))]
    [(split? tree) (split (split-axis tree)
                          (for/list ([p (in-list (split-parts tree))])
                            (cons (car p) (layout-replace-wid-node (cdr p) wid new-node))))]
    [else tree]))

;; 改某 wid 显示的视图（不动树结构 / 位置）。
(define (layout-set-pane-vid tree wid vid)
  (cond
    [(pane? tree)  (if (eqv? wid (pane-wid tree)) (pane wid vid) tree)]
    [(float? tree) (if (eqv? wid (float-wid tree))
                       (struct-copy float tree [vid vid])
                       tree)]
    [(main? tree)  (main (layout-set-pane-vid (main-tree tree) wid vid))]
    [(split? tree) (split (split-axis tree)
                          (for/list ([p (in-list (split-parts tree))])
                            (cons (car p) (layout-set-pane-vid (cdr p) wid vid))))]
    [else tree]))

;; 把 wid 所在 pane 换成「原 pane : 新 pane（nwid 显示 nvid）」的 split。
(define (layout-split-wid tree wid axis nwid nvid)
  (cond
    [(pane? tree)
     (if (eqv? wid (pane-wid tree))
         (split axis (list (cons 'flex (pane wid (pane-vid tree)))
                           (cons 'flex (pane nwid nvid))))
         tree)]
    [(main? tree) (main (layout-split-wid (main-tree tree) wid axis nwid nvid))]
    [(split? tree)
     (split (split-axis tree)
            (for/list ([p (in-list (split-parts tree))])
              (cons (car p) (layout-split-wid (cdr p) wid axis nwid nvid))))]
    [else tree]))

(define (layout-add-side tree node side size)
  (cond
    [(blank? tree) node]
    [(eq? side 'left)   (split 'h (list (cons size node) (cons 'flex tree)))]
    [(eq? side 'right)  (split 'h (list (cons 'flex tree) (cons size node)))]
    [(eq? side 'bottom) (split 'v (list (cons 'flex tree) (cons size node)))]
    [(eq? side 'top)    (split 'v (list (cons size node) (cons 'flex tree)))]
    [else tree]))

(define (layout-has-main? tree)
  (cond
    [(main? tree) #t]
    [(split? tree) (for/or ([p (in-list (split-parts tree))]) (layout-has-main? (cdr p)))]
    [else #f]))

;; 区域往「主区」里贴：只改含 main 的那一枝，兄弟（如状态栏）不动。
(define (layout-add-main tree node side size)
  (cond
    [(main? tree) (main (layout-add-side (main-tree tree) node side size))]
    [(and (split? tree) (layout-has-main? tree))
     (split (split-axis tree)
            (for/list ([p (in-list (split-parts tree))])
              (if (layout-has-main? (cdr p))
                  (cons (car p) (layout-add-main (cdr p) node side size))
                  p)))]
    [else (layout-add-side tree node side size)]))

(define (layout-add-bottom tree node h) (layout-add-side tree node 'bottom h))

(define (layout-add-float tree f)
  (cond
    [(blank? tree) f]
    [(split? tree) (split (split-axis tree) (append (split-parts tree) (list (cons 0 f))))]
    [else (split 'h (list (cons 'flex tree) (cons 0 f)))]))

(define (layout tree size)
  (define sw (car size))
  (define sh (cdr size))
  (define tiled (make-hash))          ; wid -> rect（仅本函数内部，结果确定）
  (define floats '())

  (define (split-rects r axis parts)
    (define extent (if (eq? axis 'h) (rect-w r) (rect-h r)))
    (define sizes (map car parts))
    (define fixed (for/sum ([s (in-list sizes)]) (if (number? s) s 0)))
    (define flexn (for/sum ([s (in-list sizes)]) (if (eq? s 'flex) 1 0)))
    (define remaining (max 0 (- extent fixed)))
    (define each (if (zero? flexn) 0 (quotient remaining flexn)))
    (define rem (if (zero? flexn) 0 (remainder remaining flexn)))
    (define last-flex
      (let loop ([ss sizes] [i 0] [acc #f])
        (cond [(null? ss) acc]
              [(eq? (car ss) 'flex) (loop (cdr ss) (add1 i) i)]
              [else (loop (cdr ss) (add1 i) acc)])))
    (define lens
      (for/list ([s (in-list sizes)] [i (in-naturals)])
        (cond [(number? s) s]
              [else (+ each (if (= i last-flex) rem 0))])))
    (let loop ([ps parts] [ls lens] [off 0] [acc '()])
      (cond
        [(null? ps) (reverse acc)]
        [else
         (define len (car ls))
         (define node (cdr (car ps)))
         (define rc (if (eq? axis 'h)
                        (rect (+ (rect-x r) off) (rect-y r) len (rect-h r))
                        (rect (rect-x r) (+ (rect-y r) off) (rect-w r) len)))
         (loop (cdr ps) (cdr ls) (+ off len) (cons (cons node rc) acc))])))

  (define (walk node r)
    (cond
      [(blank? node) (void)]
      [(empty-area? node) (void)]
      [(main? node) (walk (main-tree node) r)]
      [(pane? node) (hash-set! tiled (pane-wid node) r)]
      [(float? node) (set! floats (cons (cons node r) floats))]
      [(split? node)
       (for ([p (in-list (split-rects r (split-axis node) (split-parts node)))])
         (walk (car p) (cdr p)))]
      [else (error 'layout "未知布局节点: ~a" node)]))

  (define (place-float f parent)
    (define a (float-anchor f))
    (define rel
      (cond [(not (anchor-rel a)) (rect 0 0 sw sh)]
            [(hash-ref tiled (anchor-rel a) #f)]
            [parent]
            [else (rect 0 0 sw sh)]))
    (define w (min (float-want-w f) sw))
    (define h (min (float-want-h f) sh))
    (define base-x
      (case (anchor-h a)
        [(left)    (rect-x rel)]
        [(right)   (- (+ (rect-x rel) (rect-w rel)) w)]
        [(center)  (+ (rect-x rel) (quotient (- (rect-w rel) w) 2))]
        [(stretch) (rect-x rel)]
        [else      (rect-x rel)]))
    (define base-y
      (case (anchor-v a)
        [(top)     (rect-y rel)]
        [(bottom)  (- (+ (rect-y rel) (rect-h rel)) h)]
        [(center)  (+ (rect-y rel) (quotient (- (rect-h rel) h) 2))]
        [(stretch) (rect-y rel)]
        [else      (rect-y rel)]))
    (rect (clamp (+ base-x (anchor-dx a)) 0 (max 0 (- sw w)))
          (clamp (+ base-y (anchor-dy a)) 0 (max 0 (- sh h)))
          w h))

  (walk tree (rect 0 0 sw sh))

  (define ordered (reverse floats))
  (append
   (for/list ([(wid r) (in-hash tiled)])
     (define vid (layout-wid-vid tree wid))
     (placement wid vid r 0 #f))
   (for/list ([fr (in-list ordered)] [i (in-naturals)])
     (define f (car fr))
     (placement (float-wid f) (float-vid f) (place-float f (cdr fr)) (+ 1 i) #t))))
