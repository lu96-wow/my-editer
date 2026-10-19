#lang racket

;;; edit-tui-rebuild/model/layout.rkt —— split tree + panel 状态 + layout-solve
;;;
;;; 状态：
;;;   layout = root + panels + focus + next-split-id
;;;   node   = leaf(panel-id) | split(id, axis, left, right, ratio)
;;;
;;; split 关系只存结构 / 比例；rect 不进树，由 layout-solve 算。
;;; panel 资源负责 view / 固定尺寸 / 隐藏 / 恢复信息。
;;;
;;; 渲染列表 `(listof core panel)` 是 layout-solve 的投影，见 projection/geometry.rkt。
;;;
;;; 固定尺寸：
;;;   fixed-w / fixed-h 是 panel 资源上的实际值（#f = flex）。
;;;   固定轴先取，剩余给 flex；两边都固定时第二个吸收余量，保证不留空隙。
;;;   min / max 不在状态里，由调用方在 API 边界夹取。
;;;
;;; 隐藏：
;;;   panel.hidden? = #t；仍留在 split 树里。
;;;   layout-solve 跳过隐藏 leaf；兄弟吸收父 rect。
;;;   hide 记录 restore = (rect . parent-rect)；show 按比例恢复。
;;;
;;; 删除：
;;;   remove 从树里摘掉 leaf，父 split 塌缩到兄弟。
;;;   编辑区最后一个 panel 的“关掉”应使用 clear 而不是 remove。

(require "panel.rkt"
         "config.rkt"
         "../../core/view/base/rect.rkt")

(provide
 ;; ---------- 节点 ----------
 (struct-out leaf)
 (struct-out split)
 (struct-out layout)
 layout-node? layout-tree?
 layout-empty? make-layout empty-layout

 ;; ---------- panel 资源 ----------
 layout-panel-add layout-panel layout-panel-resources layout-panel-ids
 layout-focus layout-set-focus
 layout-panel-update
 layout-visible-panel-ids
 layout-panel-view-ids layout-panel-active-view
 layout-panel-set-active-view layout-panel-cycle-active-view

 ;; ---------- layout-solve ----------
 (struct-out layout-solution)
 (struct-out seam)
 layout-solve
 layout-panel-rects layout-split-rects
 layout-seams layout-seam-at layout-panel-id-at

 ;; ---------- 结构操作 ----------
 layout-split
 layout-panel-attach
 layout-panel-remove
 layout-panel-clear-content
 layout-split-set-ratio
 layout-seam-resize
 (struct-out drag)
 layout-seam-drag-start layout-seam-drag-move
 layout-panel-set-fixed

 ;; ---------- 隐藏 / 显示 ----------
 layout-panel-hide
 layout-panel-show

 ;; ---------- 查询 ----------
 layout-panel-visible? layout-subtree-visible?
 layout-panel-fixed-size
 layout-focus-fallback
 layout-validate layout-valid?)

;;; ════════════════ 节点 ════════════════

(struct leaf (panel-id) #:transparent)
(struct split (id axis left right ratio) #:transparent)
;; ratio : first child 在 flex 分配中的占比（0..1）
;;         任一边 fixed 时忽略。

(struct layout (root panel-map focus next-split-id) #:transparent)
;; panel-map : (hash/c panel-id panel)

(define empty-layout (layout #f (hash) #f 0))

(define (layout-empty? l) (not (layout-root l)))
(define (layout-node? x) (or (leaf? x) (split? x)))
(define (layout-tree? x) (or (not x) (layout-node? x)))

(define (make-layout #:root [root #f]
                     #:panels [panels (hash)]
                     #:focus [focus #f]
                     #:next-split-id [next-split-id 0])
  (layout root panels focus next-split-id))

;;; ════════════════ panel 资源 ════════════════

(define (layout-panel l id)
  (hash-ref (layout-panel-map l) id #f))

(define (layout-panel-resources l)
  (hash-values (layout-panel-map l)))

(define (layout-panel-ids l)
  (hash-keys (layout-panel-map l)))

(define (layout-panel-add l p)
  (when (layout-panel l (panel-id p))
    (error 'layout-panel-add "panel id 已存在：~a" (panel-id p)))
  (struct-copy layout l
               [panel-map (hash-set (layout-panel-map l) (panel-id p) p)]))

(define (layout-panel-update l id f)
  (define p (layout-panel l id))
  (cond
    [(not p) (values l #f)]
    [else
     (values (struct-copy layout l
                          [panel-map (hash-set (layout-panel-map l) id (f p))])
             #t)]))

(define (layout-set-focus l id)
  (struct-copy layout l [focus id]))

;;; ════════════════ panel 内的 view 顺序切换 ════════════════

(define (layout-panel-view-ids l id)
  (define p (layout-panel l id))
  (if p (panel-views p) '()))

(define (layout-panel-active-view l id)
  (define p (layout-panel l id))
  (and p (panel-active p)))

;; → (values layout' ok?)
(define (layout-panel-set-active-view l id view-id)
  (define p (layout-panel l id))
  (cond
    [(not p) (values l #f)]
    [(not (memq view-id (panel-views p))) (values l #f)]
    [else
     (layout-panel-update l id (λ (p) (panel-set-active p view-id)))]))

;; 顺序切换：step = 1 下一个，-1 上一个。
;; → (values layout' ok?)
(define (layout-panel-cycle-active-view l id [step 1])
  (define p (layout-panel l id))
  (cond
    [(not p) (values l #f)]
    [(null? (panel-views p)) (values l #f)]
    [else
     (define views (panel-views p))
     (define n (length views))
     (define cur (panel-active p))
     (define idx (or (for/first ([v (in-list views)] [i (in-naturals)]
                                 #:when (eq? v cur))
                       i)
                     0))
     (define next (list-ref views (modulo (+ idx step) n)))
     (layout-panel-update l id (λ (p) (panel-set-active p next)))]))


;;; ════════════════ 可见性 / 固定 ════════════════

(define (leaf-visible? l leaf)
  (define p (layout-panel l (leaf-panel-id leaf)))
  (and p (panel-visible? p)))

(define (layout-subtree-visible? l n)
  (cond
    [(not n) #f]
    [(leaf? n) (leaf-visible? l n)]
    [else (or (layout-subtree-visible? l (split-left n))
              (layout-subtree-visible? l (split-right n)))]))

(define (layout-panel-visible? l id)
  (define p (layout-panel l id))
  (and p (panel-visible? p)))

(define (node-fixed-size l n axis)
  (cond
    [(leaf? n)
     (define p (layout-panel l (leaf-panel-id n)))
     (and p
          (panel-visible? p)
          (case axis
            [(lr) (panel-fixed-w p)]
            [(tb) (panel-fixed-h p)]
            [else (error 'node-fixed-size "axis 要是 'lr 或 'tb：~a" axis)]))]
    [else #f]))

(define (layout-panel-fixed-size l id axis)
  (define p (layout-panel l id))
  (and p
       (case axis
         [(lr) (panel-fixed-w p)]
         [(tb) (panel-fixed-h p)]
         [else (error 'layout-panel-fixed-size "axis 要是 'lr 或 'tb：~a" axis)])))

;;; ════════════════ layout-solve ════════════════

(struct seam (split-id axis rect) #:transparent)
(struct layout-solution (panel-rects split-rects seams) #:transparent)
;; panel-rects : panel-id -> rect（仅可见 panel）
;; split-rects : split-id -> rect
;; seams       : (listof seam)，按树序

(define (axis-extent r axis)
  (case axis
    [(lr) (rect-w r)]
    [(tb) (rect-h r)]
    [else (error 'axis-extent "axis 要是 'lr 或 'tb：~a" axis)]))

(define (round-ratio E ratio)
  (max 0 (min E (inexact->exact (round (* E ratio))))))

;; → (values first-extent second-extent)
(define (allocate E fixed-first fixed-second ratio)
  (define E* (max 0 E))
  (cond
    [(and fixed-first fixed-second)
     (define f (min E* fixed-first))
     (values f (- E* f))]
    [fixed-first
     (define f (min E* fixed-first))
     (values f (- E* f))]
    [fixed-second
     (define s (min E* fixed-second))
     (values (- E* s) s)]
    [else
     (define f (round-ratio E* ratio))
     (values f (- E* f))]))

(define (make-seam-rect axis left-r right-r)
  (case axis
    [(lr) (rect (rect-x right-r) (rect-y right-r)
                1 (rect-h right-r))]
    [(tb) (rect (rect-x right-r) (rect-y right-r)
                (rect-w right-r) 1)]
    [else (error 'make-seam-rect "axis 要是 'lr 或 'tb：~a" axis)]))

(define (layout-solve l area)
  (define rects (make-hasheq))
  (define split-rects (make-hasheq))
  (define seams '())
  (define (walk n r)
    (cond
      [(not n) (void)]
      [(leaf? n)
       (when (layout-subtree-visible? l n)
         (hash-set! rects (leaf-panel-id n) r))]
      [else
       (hash-set! split-rects (split-id n) r)
       (define axis (split-axis n))
       (define left (split-left n))
       (define right (split-right n))
       (define lv? (layout-subtree-visible? l left))
       (define rv? (layout-subtree-visible? l right))
       (cond
         [(not lv?)
          (when rv? (walk right r))]
         [(not rv?)
          (walk left r)]
         [else
          (define E (axis-extent r axis))
          (define-values (e1 e2)
            (allocate E
                      (node-fixed-size l left axis)
                      (node-fixed-size l right axis)
                      (split-ratio n)))
          (define-values (r1 r2)
            (case axis
              [(lr)
               (values (rect (rect-x r) (rect-y r) e1 (rect-h r))
                       (rect (+ (rect-x r) e1) (rect-y r) e2 (rect-h r)))]
              [(tb)
               (values (rect (rect-x r) (rect-y r) (rect-w r) e1)
                       (rect (rect-x r) (+ (rect-y r) e1) (rect-w r) e2))]))
          (walk left r1)
          (walk right r2)
          (set! seams (cons (seam (split-id n) axis (make-seam-rect axis r1 r2))
                            seams))])]))
  (walk (layout-root l) area)
  (layout-solution rects split-rects (reverse seams)))

(define (layout-panel-rects l area)
  (layout-solution-panel-rects (layout-solve l area)))

(define (layout-split-rects l area)
  (layout-solution-split-rects (layout-solve l area)))

(define (layout-seams l area)
  (layout-solution-seams (layout-solve l area)))

(define (layout-seam-at l area row col)
  (for/first ([s (in-list (layout-seams l area))]
              #:when (rect-contains? (seam-rect s) col row))
    s))

(define (layout-panel-id-at l area row col)
  (for/first ([(id r) (in-hash (layout-panel-rects l area))]
              #:when (rect-contains? r col row))
    id))


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

;; 树序的可见 panel id
(define (layout-visible-panel-ids l)
  (define out '())
  (define (walk n)
    (cond
      [(not n) (void)]
      [(leaf? n) (when (layout-subtree-visible? l n)
                   (set! out (cons (leaf-panel-id n) out)))]
      [else (walk (split-left n)) (walk (split-right n))]))
  (walk (layout-root l))
  (reverse out))

(define (first-visible-panel-id l)
  (for/first ([id (in-list (layout-visible-panel-ids l))]) id))

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
                      #:config [config default-config])
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

(define (layout-panel-remove l id #:config [config default-config])
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
  (layout-panel-update l id (λ (p) (panel-set-fixed p axis value))))

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

;;; ════════════════ ratio / seam resize ════════════════

(define (layout-split-set-ratio l sid ratio)
  (unless (and (real? ratio) (<= 0 ratio 1))
    (error 'layout-split-set-ratio "ratio 要在 [0,1]：~a" ratio))
  (define-values (root* changed?)
    (update-split (layout-root l) sid
                  (λ (s) (struct-copy split s [ratio ratio]))))
  (values (if changed? (struct-copy layout l [root root*]) l)
          changed?))

;; delta 是沿 split 轴的格数；只有两边都 flex 时才能拖。
(define (layout-seam-resize l area sid delta #:config [config default-config])
  (define s (find-split (layout-root l) sid))
  (cond
    [(not s) (values l #f)]
    [(not (and (layout-subtree-visible? l (split-left s))
               (layout-subtree-visible? l (split-right s))))
     (values l #f)]
    [(or (node-fixed-size l (split-left s) (split-axis s))
         (node-fixed-size l (split-right s) (split-axis s)))
     (values l #f)]
    [else
     (define r (hash-ref (layout-split-rects l area) sid #f))
     (cond
       [(not r) (values l #f)]
       [else
        (define E (axis-extent r (split-axis s)))
        (cond
          [(zero? E) (values l #f)]
          [else
           (define b (seam-bounds l config s E))
           (cond
             [(not b) (values l #f)]
             [else
              (define lower (car b))
              (define upper (cdr b))
              (define cur (round-ratio E (split-ratio s)))
              (define new-left (max lower (min upper (+ cur delta))))
              (layout-split-set-ratio l sid (/ new-left E))])])])]))

;;; ════════════════ 拖动状态 ════════════════

;; 拖动只记录：哪条 split、从哪个指针位置开始、开始时 ratio。
;; move 用“从起点到当前的绝对 delta”，所以重复 move 不会累积错。
(struct drag (split-id axis start-row start-col start-ratio) #:transparent)

(define (layout-seam-drag-start l area row col #:config [config default-config])
  (define s* (layout-seam-at l area row col))
  (cond
    [(not s*) #f]
    [else
     (define s (find-split (layout-root l) (seam-split-id s*)))
     (cond
       [(not s) #f]
       [(or (node-fixed-size l (split-left s) (split-axis s))
            (node-fixed-size l (split-right s) (split-axis s)))
        #f]
       [else
        (define r (hash-ref (layout-split-rects l area) (split-id s) #f))
        (and r
             (seam-bounds l config s (axis-extent r (split-axis s)))
             (drag (split-id s) (split-axis s) row col (split-ratio s)))])]))

(define (layout-seam-drag-move l area d row col #:config [config default-config])
  (define s (find-split (layout-root l) (drag-split-id d)))
  (cond
    [(not s) (values l #f)]
    [(or (node-fixed-size l (split-left s) (drag-axis d))
         (node-fixed-size l (split-right s) (drag-axis d)))
     (values l #f)]
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
           (define b (seam-bounds l config s E))
           (cond
             [(not b) (values l #f)]
             [else
              (define lower (car b))
              (define upper (cdr b))
              (define delta (if (eq? axis 'lr)
                                (- col (drag-start-col d))
                                (- row (drag-start-row d))))
              (define start-left (round-ratio E (drag-start-ratio d)))
              (define new-left (max lower (min upper (+ start-left delta))))
              (layout-split-set-ratio l (drag-split-id d) (/ new-left E))])])])]))

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

(define (layout-panel-hide l area id #:config [config default-config])
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

(define (layout-panel-show l area id)
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
        (define fixed (layout-panel-fixed-size l1 id axis))
        (cond
          [fixed (values l1 #t)]         ; 固定轴：比例不重要
          [else
           (define r (restore-ratio p axis))
           (define r* (if (eq? side 'left) r (- 1 r)))
           (define-values (l2 _) (layout-split-set-ratio l1 (split-id parent) r*))
           (values l2 #t)])])]))

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
