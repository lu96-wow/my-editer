#lang racket

;;; edit-tui-rebuild/layout/tree.rkt —— split tree + panel 资源 + 可见性 / 固定尺寸
;;;
;;; 状态：
;;;   layout = root + panel-map + focus + next-split-id
;;;   node   = leaf(panel-id) | split(id axis left right ratio)
;;;
;;; 只存结构 / 比例；rect 不进树（由 solve.rkt 算）。
;;; 本模块只做「数据 + 纯查询」，不做布局求解、不做结构编辑。

(require "../panel/model.rkt")

(provide
 (struct-out leaf)
 (struct-out split)
 (struct-out layout)
 empty-layout
 layout-empty?
 layout-node?
 layout-tree?
 make-layout
 make-leaf
 layout-panel
 layout-panel-resources
 layout-panel-for-view
 layout-panel-ids
 layout-panel-add
 layout-panel-add-view
 layout-panel-update
 layout-set-focus
 layout-panel-view-ids
 layout-panel-active-view
 layout-panel-set-active-view
 layout-panel-cycle-active-view
 leaf-visible?
 layout-subtree-visible?
 layout-panel-visible?
 node-fixed-size
 layout-panel-fixed-size
 layout-visible-panel-ids
 first-visible-panel-id)

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

(define (make-leaf panel-id)
  (when (not panel-id)
    (error 'make-leaf "panel-id 不能是 #f"))
  (leaf panel-id))

;;; ════════════════ panel 资源 ════════════════

(define (layout-panel l id)
  (hash-ref (layout-panel-map l) id #f))

(define (layout-panel-resources l)
  (hash-values (layout-panel-map l)))

;; 哪个 panel 当前挂着这个 view（反向查询，给“聚焦已有 view”用）。
(define (layout-panel-for-view l vid)
  (for/first ([p (in-list (layout-panel-resources l))]
              #:when (memv vid (panel-views p)))
    (panel-id p)))

(define (layout-panel-ids l)
  (hash-keys (layout-panel-map l)))

(define (layout-panel-add l p)
  (when (layout-panel l (panel-id p))
    (error 'layout-panel-add "panel id 已存在：~a" (panel-id p)))
  (struct-copy layout l
               [panel-map (hash-set (layout-panel-map l) (panel-id p) p)]))

(define (layout-panel-add-view l id vid)
  (layout-panel-update l id
    (λ (p)
      (define views (if (memv vid (panel-views p))
                        (panel-views p)
                        (append (panel-views p) (list vid))))
      (panel-set-views p views vid))))

(define (layout-panel-update l id f)
  (define p (layout-panel l id))
  (cond
    [(not p) (values l #f)]
    [else
     (values (struct-copy layout l
                          [panel-map (hash-set (layout-panel-map l) id (f p))])
             #t)]))

(define (layout-set-focus l id)
  ;; 焦点没变时保留同一个 layout 对象，布局求解缓存可以继续命中。
  (if (equal? (layout-focus l) id)
      l
      (struct-copy layout l [focus id])))

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

