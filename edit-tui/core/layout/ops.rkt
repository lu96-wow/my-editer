#lang racket

;;; edit-tui-rebuild/core/layout/ops.rkt —— split tree 的结构编辑 / 焦点回退 / 拖动
;;;
;;; 建 split、attach / remove / hide / show、改比例、拖 seam、校验。
;;; rect 换算走 solve.rkt；树结构走 tree.rkt。
;;; 修改布局不碰 view / engine —— 那些由调用方（app / runtime）处理。
;;;
;;; config 是**必填参数**：这一层不知道任何具体 kind 规则。
;;; 具体配置由宿主选择（config/layout/default.rkt）并传进来。

(require racket/list
         "../../../core/view/base/rect.rkt"
         "config.rkt"
         "../panel/model.rkt"
         "tree.rkt"
         "solve.rkt")

(provide
 (struct-out drag)
 find-parent-split
 replace-leaf
 update-split
 find-split
 remove-leaf
 direction->axis
 tree-has-leaf?
 panel-focusable?
 first-focusable-in-node
 first-focusable-panel-id
 sibling-path
 layout-focus-fallback
 insert-node
 layout-split
 layout-panel-attach
 layout-panel-remove
 layout-panel-clear-content
 layout-panel-set-fixed
 visible-children
 panel-min-size
 panel-max-size
 node-min-size
 node-max-size
 seam-bounds
 layout-split-set-ratio
 layout-seam-resize
 layout-seam-drag-start
 layout-seam-drag-move
 parent-rect-for
 axis-size
 layout-panel-hide
 restore-ratio
 layout-panel-show
 layout-validate
 layout-valid?)

;;; ════════════════ 树更新 ════════════════

(define (find-parent-split n id)
  ;; → (values parent-split side) | (values #f #f)
  ;; side = 'left | 'right
  (cond
    [(not n) (values #f #f)]
    [(leaf? n) (values #f #f)]
    [else
     (define ls (split-left n))
     (define rs (split-right n))
     (cond
       [(and (leaf? ls) (equal? (leaf-panel-id ls) id))
        (values n 'left)]
       [(and (leaf? rs) (equal? (leaf-panel-id rs) id))
        (values n 'right)]
       [else
        (define-values (p side) (find-parent-split ls id))
        (if p
            (values p side)
            (find-parent-split rs id))])]))

(define (replace-leaf n id replacement)
  (cond
    [(not n) #f]
    [(leaf? n) (if (equal? (leaf-panel-id n) id) replacement n)]
    [else (split (split-id n) (split-axis n)
                 (replace-leaf (split-left n) id replacement)
                 (replace-leaf (split-right n) id replacement)
                 (split-ratio n))]))

(define (update-split n sid f)
  ;; → (values node' changed?)
  (cond
    [(not n) (values #f #f)]
    [(leaf? n) (values n #f)]
    [(equal? (split-id n) sid) (values (f n) #t)]
    [else
     (define-values (l l?) (update-split (split-left n) sid f))
     (define-values (r r?) (update-split (split-right n) sid f))
     (values (split (split-id n) (split-axis n) l r (split-ratio n))
             (or l? r?))]))

(define (find-split n sid)
  (cond
    [(not n) #f]
    [(leaf? n) #f]
    [(equal? (split-id n) sid) n]
    [else (or (find-split (split-left n) sid)
              (find-split (split-right n) sid))]))

;; → (values node'|#f direct-removed? found?)
(define (remove-leaf n id)
  (cond
    [(not n) (values #f #f #f)]
    [(leaf? n)
     (if (equal? (leaf-panel-id n) id)
         (values #f #t #t)
         (values n #f #f))]
    [else
     (define-values (l l-direct? l-found?) (remove-leaf (split-left n) id))
     (define-values (r r-direct? r-found?) (remove-leaf (split-right n) id))
     (cond
       [(and l-direct? r-direct?) (values #f #t #t)]
       [l-direct? (values r #f #t)]
       [r-direct? (values l #f #t)]
       [else (values (split (split-id n) (split-axis n) l r (split-ratio n))
                     #f (or l-found? r-found?))])]))


;;; ════════════════ 方向 / 插入 ════════════════

(define (direction->axis dir)
  (case dir
    [(left)  (values 'lr #t)]
    [(right) (values 'lr #f)]
    [(up)    (values 'tb #t)]
    [(down)  (values 'tb #f)]
    [else (error 'layout "dir 要是 left/right/up/down：~a" dir)]))

(define (tree-has-leaf? n id)
  (cond
    [(not n) #f]
    [(leaf? n) (equal? (leaf-panel-id n) id)]
    [else (or (tree-has-leaf? (split-left n) id)
              (tree-has-leaf? (split-right n) id))]))

;;; ════════════════ 焦点回退 ════════════════

(define (panel-focusable? l config id)
  (define p (layout-panel l id))
  (and p
       (panel-visible? p)
       (config-panel-focusable? config (panel-kind p))))

(define (first-focusable-in-node l config n)
  (cond
    [(not n) #f]
    [(leaf? n)
     (define id (leaf-panel-id n))
     (and (panel-focusable? l config id) id)]
    [else (or (first-focusable-in-node l config (split-left n))
              (first-focusable-in-node l config (split-right n)))]))

(define (first-focusable-panel-id l config)
  (first-focusable-in-node l config (layout-root l)))

;; 从内到外的兄弟节点：先父 split 的兄弟，再更上层。
(define (sibling-path n id)
  (cond
    [(not n) '()]
    [(leaf? n) '()]
    [else
     (define l (split-left n))
     (define r (split-right n))
     (cond
       [(tree-has-leaf? l id) (cons r (sibling-path l id))]
       [(tree-has-leaf? r id) (cons l (sibling-path r id))]
       [else '()])]))

;; 失去焦点的 panel：兄弟子树优先，然后逐层向上，最后第一个可聚焦 panel。
(define (layout-focus-fallback l config id)
  (or (for/or ([n (in-list (sibling-path (layout-root l) id))])
        (first-focusable-in-node l config n))
      (first-focusable-panel-id l config)))


;; → (values layout' split-id|#f ok?)
(define (insert-node l target-id dir new-panel #:ratio [ratio 1/2])
  (define target-panel (layout-panel l target-id))
  (cond
    [(not target-panel) (values l #f #f)]
    [(not (tree-has-leaf? (layout-root l) target-id)) (values l #f #f)]
    [(not (panel-visible? target-panel)) (values l #f #f)]
    [(layout-panel l (panel-id new-panel))
     (error 'layout-panel-attach "panel id 已存在：~a" (panel-id new-panel))]
    [else
     (define-values (axis new-first?) (direction->axis dir))
     (define sid (layout-next-split-id l))
     (define old-leaf (leaf target-id))
     (define new-leaf (leaf (panel-id new-panel)))
     (define node (if new-first?
                      (split sid axis new-leaf old-leaf ratio)
                      (split sid axis old-leaf new-leaf ratio)))
     (define l1 (struct-copy layout l
                             [root (replace-leaf (layout-root l) target-id node)]
                             [panel-map (hash-set (layout-panel-map l)
                                                  (panel-id new-panel) new-panel)]
                             [next-split-id (add1 sid)]))
     (values l1 sid #t)]))

(define (layout-split l target-id dir new-panel-id
                      #:ratio [ratio 1/2]
                      #:config config)
  (define target (layout-panel l target-id))
  (cond
    [(not target) (values l #f)]
    [(not (config-panel-splittable? config (panel-kind target))) (values l #f)]
    [(panel-hidden? target) (values l #f)]
    [else
     ;; 新 panel 与目标同 kind、空内容；固定尺寸不继承。
     (define p (make-panel new-panel-id (panel-kind target)
                           #:views '()
                           #:active #f
                           #:borders (panel-borders target)
                           #:face (panel-face target)
                           #:weight (panel-weight target)))
     (define-values (l* _sid ok?) (insert-node l target-id dir p #:ratio ratio))
     (values l* ok?)]))

(define (layout-panel-attach l target-id dir p #:ratio [ratio 1/2])
  (define-values (l* _sid ok?) (insert-node l target-id dir p #:ratio ratio))
  (values l* ok?))

;;; ════════════════ 删除 / 清空 ════════════════

(define (layout-panel-remove l id #:config config)
  (define p (layout-panel l id))
  (cond
    [(not p) (values l #f)]
    [(not (config-panel-deletable? config (panel-kind p))) (values l #f)]
    [else
     (define-values (root* _direct? found?) (remove-leaf (layout-root l) id))
     (cond
       [(not found?) (values l #f)]
       [else
        (define l1 (struct-copy layout l
                                [root root*]
                                [panel-map (hash-remove (layout-panel-map l) id)]))
        (define l2 (if (equal? (layout-focus l1) id)
                       (layout-set-focus l1 (layout-focus-fallback l1 config id))
                       l1))
        (values l2 #t)])]))

;; 只清内容，不删 panel / split 关系。用于“最后一个 editor 关掉”。
(define (layout-panel-clear-content l id)
  (layout-panel-update l id
                       (λ (p) (panel-set-views p '() #f))))

(define (layout-panel-set-fixed l id axis value)
  (define panel-axis (case axis
                       [(lr) 'w]
                       [(tb) 'h]
                       [else (error 'layout-panel-set-fixed
                                    "axis 要是 'lr 或 'tb：~a" axis)]))
  (layout-panel-update l id (λ (p) (panel-set-fixed p panel-axis value))))

;;; ════════════════ 尺寸限制 ════════════════

(define (visible-children l n)
  (filter (λ (c) (layout-subtree-visible? l c))
          (list (split-left n) (split-right n))))

(define (panel-min-size l config id axis)
  (define p (layout-panel l id))
  (cond
    [(or (not p) (not (panel-visible? p))) 0]
    [else (panel-rule-min-size (config-panel-rule config (panel-kind p)) axis)]))

(define (panel-max-size l config id axis)
  (define p (layout-panel l id))
  (cond
    [(or (not p) (not (panel-visible? p))) #f]
    [else (panel-rule-max-size (config-panel-rule config (panel-kind p)) axis)]))

;; 子树沿某个轴的最小 / 最大格数。
;; 同轴 split：孩子加起来；垂直轴 split：取孩子的 max / min。
(define (node-min-size l config n axis)
  (cond
    [(not n) 0]
    [(leaf? n) (panel-min-size l config (leaf-panel-id n) axis)]
    [else
     (define kids (visible-children l n))
     (cond
       [(null? kids) 0]
       [(eq? (split-axis n) axis)
        (apply + (for/list ([c (in-list kids)]) (node-min-size l config c axis)))]
       [else
        (apply max (for/list ([c (in-list kids)]) (node-min-size l config c axis)))])]))

(define (node-max-size l config n axis)
  (cond
    [(not n) #f]
    [(leaf? n) (panel-max-size l config (leaf-panel-id n) axis)]
    [else
     (define kids (visible-children l n))
     (cond
       [(null? kids) #f]
       [(eq? (split-axis n) axis)
        (define ms (for/list ([c (in-list kids)]) (node-max-size l config c axis)))
        (and (for/and ([m (in-list ms)]) m) (apply + ms))]
       [else
        (define ms (filter values
                           (for/list ([c (in-list kids)])
                             (node-max-size l config c axis))))
        (and (pair? ms) (apply min ms))])]))

;; 接缝可移动范围 → (cons lower upper) | #f
(define (seam-bounds l config s E)
  (define axis (split-axis s))
  (define left (split-left s))
  (define right (split-right s))
  (define min-l (node-min-size l config left axis))
  (define max-l (node-max-size l config left axis))
  (define min-r (node-min-size l config right axis))
  (define max-r (node-max-size l config right axis))
  (define lower (max min-l (if max-r (max 0 (- E max-r)) 0)))
  (define upper (min (if max-l (min E max-l) E) (- E min-r)))
  (and (<= lower upper) (cons lower upper)))

;; 接缝哪一侧是 fixed。leaf 才有 fixed size；两边都 fixed 时优先左边。
(define (seam-fixed-side l s axis)
  (cond
    [(node-fixed-size l (split-left s) axis) 'left]
    [(node-fixed-size l (split-right s) axis) 'right]
    [else #f]))

;; 接缝左侧当前宽度（fixed 侧或 flex ratio）。
(define (seam-start-left l s E fixed-side)
  (define axis (split-axis s))
  (case fixed-side
    [(left) (node-fixed-size l (split-left s) axis)]
    [(right) (- E (node-fixed-size l (split-right s) axis))]
    [else (round-ratio E (split-ratio s))]))

;; 把“左侧宽度”写回 layout：fixed 侧改 fixed size，flex/flex 改 ratio。
(define (seam-apply-left l s E new-left fixed-side)
  (define axis (split-axis s))
  (case fixed-side
    [(left)
     (layout-panel-set-fixed l (leaf-panel-id (split-left s)) axis new-left)]
    [(right)
     (layout-panel-set-fixed l (leaf-panel-id (split-right s))
                             axis (- E new-left))]
    [else
     (layout-split-set-ratio l (split-id s) (/ new-left E))]))

;;; ════════════════ ratio / seam resize ════════════════

(define (layout-split-set-ratio l sid ratio)
  (unless (and (real? ratio) (<= 0 ratio 1))
    (error 'layout-split-set-ratio "ratio 要在 [0,1]：~a" ratio))
  (define-values (root* changed?)
    (update-split (layout-root l) sid
                  (λ (s) (struct-copy split s [ratio ratio]))))
  (values (if changed? (struct-copy layout l [root root*]) l)
          changed?))

;; delta 是沿 split 轴的格数。flex/flex 改 ratio；一侧 fixed 时改 fixed size。
(define (layout-seam-resize l area sid delta #:config config)
  (define s (find-split (layout-root l) sid))
  (cond
    [(not s) (values l #f)]
    [(not (and (layout-subtree-visible? l (split-left s))
               (layout-subtree-visible? l (split-right s))))
     (values l #f)]
    [else
     (define axis (split-axis s))
     (define r (hash-ref (layout-split-rects l area) sid #f))
     (cond
       [(not r) (values l #f)]
       [else
        (define E (axis-extent r axis))
        (cond
          [(zero? E) (values l #f)]
          [else
           (define fixed-side (seam-fixed-side l s axis))
           (define b (seam-bounds l config s E))
           (cond
             [(not b) (values l #f)]
             [else
              (define lower (car b))
              (define upper (cdr b))
              (define cur (seam-start-left l s E fixed-side))
              (define new-left (max lower (min upper (+ cur delta))))
              (seam-apply-left l s E new-left fixed-side)])])])]))

;;; ════════════════ 拖动状态 ════════════════

;; 拖动只记录：哪条 split、从哪个指针位置开始、开始时 ratio / 左侧宽度 / fixed 侧。
;; move 用“从起点到当前的绝对 delta”，所以重复 move 不会累积错。
(struct drag
  (split-id axis start-row start-col start-ratio start-left fixed-side)
  #:transparent)

;; seam / solution 可由 layout-hit 传入，避免 press 路径重复 solve。
(define (layout-seam-drag-start l area row col
                                #:config config
                                #:seam [seam #f]
                                #:solution [solution #f])
  (define s* (or seam (layout-seam-at l area row col)))
  (cond
    [(not s*) #f]
    [else
     (define s (find-split (layout-root l) (seam-split-id s*)))
     (cond
       [(not s) #f]
       [else
        (define solution* (or solution (layout-solve l area)))
        (define r (hash-ref (layout-solution-split-rects solution*)
                            (split-id s) #f))
        (and r
             (let* ([axis (split-axis s)]
                    [E (axis-extent r axis)]
                    [fixed-side (seam-fixed-side l s axis)])
               (and (seam-bounds l config s E)
                    (drag (split-id s) axis row col (split-ratio s)
                          (seam-start-left l s E fixed-side)
                          fixed-side))))])]))

(define (layout-seam-drag-move l area d row col #:config config)
  (define s (find-split (layout-root l) (drag-split-id d)))
  (cond
    [(not s) (values l #f)]
    [else
     (define axis (drag-axis d))
     (define r (hash-ref (layout-split-rects l area) (drag-split-id d) #f))
     (cond
       [(not r) (values l #f)]
       [else
        (define E (axis-extent r axis))
        (cond
          [(zero? E) (values l #f)]
          [else
           (define fixed-side (drag-fixed-side d))
           (define b (seam-bounds l config s E))
           (cond
             [(not b) (values l #f)]
             [else
              (define lower (car b))
              (define upper (cdr b))
              (define delta (if (eq? axis 'lr)
                                (- col (drag-start-col d))
                                (- row (drag-start-row d))))
              (define start-left
                (if fixed-side
                    (drag-start-left d)
                    (round-ratio E (drag-start-ratio d))))
              (define new-left (max lower (min upper (+ start-left delta))))
              (seam-apply-left l s E new-left fixed-side)])])])]))

;;; ════════════════ 隐藏 / 显示 ════════════════

(define (parent-rect-for l area id)
  (define-values (parent side) (find-parent-split (layout-root l) id))
  (cond
    [parent
     (or (hash-ref (layout-split-rects l area) (split-id parent) #f)
         area)]
    [else area]))

(define (axis-size r axis)
  (axis-extent r axis))

(define (layout-panel-hide l area id #:config config)
  (define p (layout-panel l id))
  (cond
    [(or (not p) (panel-hidden? p)) (values l #f)]
    [(not (config-panel-hideable? config (panel-kind p))) (values l #f)]
    [else
     (define pass (layout-solve l area))
     (define r (hash-ref (layout-solution-panel-rects pass) id #f))
     (cond
       [(not r) (values l #f)]
       [else
        (define pr (parent-rect-for l area id))
        (define p* (panel-set-hidden p #t (restore r pr)))
        (define l1 (struct-copy layout l
                                [panel-map (hash-set (layout-panel-map l) id p*)]))
        (define l2 (if (equal? (layout-focus l1) id)
                       (layout-set-focus l1 (layout-focus-fallback l1 config id))
                       l1))
        (values l2 #t)])]))

(define (restore-ratio p axis)
  (define r (panel-restore p))
  (cond
    [(not r) 1/2]
    [else
     (define rr (restore-rect r))
     (define pr (restore-parent-rect r))
     (define old-E (axis-size pr axis))
     (define old-S (axis-size rr axis))
     (if (and old-E (> old-E 0))
         (/ old-S old-E)
         1/2)]))

(define (layout-panel-show l area id #:config [config empty-layout-config])
  (define p (layout-panel l id))
  (cond
    [(or (not p) (not (panel-hidden? p))) (values l #f)]
    [else
     (define p* (panel-set-hidden p #f))
     (define l1 (struct-copy layout l
                             [panel-map (hash-set (layout-panel-map l) id p*)]))
     (define-values (parent side) (find-parent-split (layout-root l1) id))
     (cond
       [(not parent) (values l1 #t)]
       [else
        (define axis (split-axis parent))
        (define solution (layout-solve l1 area))
        (define pr (hash-ref (layout-solution-split-rects solution)
                             (split-id parent) #f))
        (define E (and pr (axis-extent pr axis)))
        (cond
          [(or (not E) (zero? E)) (values l1 #t)]
          [else
           (define b (seam-bounds l1 config parent E))
           (cond
             [(not b) (values l #f)]     ; 没有合法尺寸：保持隐藏
             [else
              (define lower (car b))
              (define upper (cdr b))
              (define fixed (layout-panel-fixed-size l1 id axis))
              (define desired-left
                (if fixed
                    (if (eq? side 'left) fixed (- E fixed))
                    (let* ([r (restore-ratio p axis)]
                           [s (round-ratio E r)])
                      (if (eq? side 'left) s (- E s)))))
              (define new-left (max lower (min upper desired-left)))
              (cond
                [fixed
                 (define new-fixed (if (eq? side 'left) new-left (- E new-left)))
                 (layout-panel-set-fixed l1 id axis new-fixed)]
                [else
                 (layout-split-set-ratio l1 (split-id parent) (/ new-left E))])])])])]))

;;; ════════════════ 校验 ════════════════

;; 检查每个可见 panel 的当前 rect 是否满足 config 的 min / max。
;; → (listof (list panel-id axis actual min max))
(define (layout-validate l area config)
  (define pass (layout-solve l area))
  (append*
   (for/list ([(id r) (in-hash (layout-solution-panel-rects pass))])
     (define p (layout-panel l id))
     (define rule (config-panel-rule config (panel-kind p)))
     (define w (rect-w r))
     (define h (rect-h r))
     (append
      (cond
        [(< w (panel-rule-min-w rule))
         (list (list id 'w w (panel-rule-min-w rule) (panel-rule-max-w rule)))]
        [(and (panel-rule-max-w rule) (> w (panel-rule-max-w rule)))
         (list (list id 'w w (panel-rule-min-w rule) (panel-rule-max-w rule)))]
        [else '()])
      (cond
        [(< h (panel-rule-min-h rule))
         (list (list id 'h h (panel-rule-min-h rule) (panel-rule-max-h rule)))]
        [(and (panel-rule-max-h rule) (> h (panel-rule-max-h rule)))
         (list (list id 'h h (panel-rule-min-h rule) (panel-rule-max-h rule)))]
        [else '()])))))

(define (layout-valid? l area config)
  (null? (layout-validate l area config)))
