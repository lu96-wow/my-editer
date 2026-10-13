#lang racket

;;; edit4/content/region.rkt —— 面板槽（dock / region）：一个窗口显示多个面板之一
;;;
;;; region = 边/尺寸/组合/当前成员/锚点/窗口/次序/常驻叶子；成员互斥显示。
;;;   mount  ：在布局里插入一个常驻叶子（min (0 . 0)），shown? 决定初始 size；
;;;   show   ：展开常驻叶子（size 改回记住的值）——不改结构，顺序/id 稳定；
;;;   hide   ：折叠常驻叶子（size 0，记住当前尺寸）——同样不改结构；
;;;   cycle/activate/focus：换成员 / 聚焦（隐藏则先展开）。
;;;
;;; 显隐 = **尺寸手术**（可折叠子节点，见 layout/tree.rkt 的 collapsed-child?）：
;;; 叶子一直在树里，折叠时不占位置、不占缝、不参与命中。这样 toggle 幂等、
;;; 窗口 id 跨显隐稳定、root 区域嵌套顺序恒等于声明顺序。

(provide region-commands region-ref region-show region-hide region-mount region-activate!)

(require racket/list
         "../core/world.rkt" "../core/command.rkt"
         "../layout.rkt"
         "model.rkt" "adapter.rkt" "lifecycle.rkt")

(define (region-ref w rid) (hash-ref (content-regions (world-content w)) rid #f))

(define (region-set w rid r)
  (define c (world-content w))
  (world-set-content w (content-set-regions c (hash-set (content-regions c) rid r))))

(define (region-set-active w rid name)
  (define r (region-ref w rid))
  (if r (region-set w rid (struct-copy region r [active name])) w))

;; 把常驻叶子的 vid 换成 active 成员的 vid（隐藏的 dock 也绑，保证叶子永远是「面板窗」）。
(define (region-sync w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (define id (and r (region-leaf r)))
  (cond
    [(not (and c id)) w]
    [else (define vid (content-panel-vid c (region-active r)))
          (if vid (world-set-content w (content-bind c id vid)) w)]))

;; 挂载 dock：插入常驻叶子（min (0 . 0)），shown? 决定初始 size。
(define (region-mount w rid #:shown? [shown? #f])
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not r) w]
    [else
     (define lay (world-layout w))
     (define nid (fresh-id lay))
     (define mn (region-min-size r))
     ;; 叶子 min = dock 最小尺寸：拖拽/缩屏不会把它挤到 0；折叠靠 basis 0，不受 min 影响。
     (define nleaf (leaf nid (cons mn mn)))
     (define sz (size (if shown? (max mn (region-size r)) 0) #f))
     (define nlay
       (case (region-anchor r)
         [(main) (define target (content-editor-window c lay))
                 (if target (insert-adjacent lay target (region-side r) sz nleaf)
                     (insert-side lay (region-side r) sz nleaf))]
         [else (insert-side lay (region-side r) sz nleaf)]))
     (define r* (struct-copy region r [leaf nid] [wid (and shown? nid)]))
     (region-sync (region-set (world-set-layout w nlay) rid r*) rid)]))

;; 某个窗口在布局里的当前尺寸意图（basis）——拖拽会更新它；找不到 → #f。
(define (window-basis-width lay id)
  (define p (path-of lay id))
  (and p (pair? p)
       (let ([parent (node-at lay (drop-right p 1))])
         (and (split? parent)
              (let ([c (list-ref (split-kids parent) (last p))])
                (size-basis (child-size c)))))))

;; 把常驻叶子的 size 设为 b（dock 恒固定；b = 0 即折叠）。
(define (set-leaf-size lay id b)
  (define p (path-of lay id))
  (cond
    [(and p (pair? p))
     (define idx (last p))
     (modify-path lay (drop-right p 1)
                  (lambda (node)
                    (split (split-axis node) (split-gutter node)
                           (for/list ([c (in-list (split-kids node))] [i (in-naturals)])
                             (if (= i idx)
                                 (child (size b #f) (child-node c))
                                 c)))))]
    [else lay]))

;; 显示：展开常驻叶子。
(define (region-show w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r)) w]
    [(region-wid r) (region-sync w rid)]
    [else
     (define L (region-leaf r))
     (cond
       [(not L) w]
       [else
        (define lay (set-leaf-size (world-layout w) L (max (region-min-size r) (region-size r))))
        (region-sync (region-set (world-set-layout w lay) rid (struct-copy region r [wid L])) rid)])]))

;; 隐藏：折叠常驻叶子（记住当前尺寸）。
(define (region-hide w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r (region-wid r))) w]
    [else
     (define L (region-leaf r))
     (define cur (window-basis-width (world-layout w) L))
     (define lay (set-leaf-size (world-layout w) L 0))
     (define r* (struct-copy region r [wid #f]
                                       [size (max (region-min-size r) (or cur (region-size r)))]))
     (ensure-focus (region-set (world-set-layout w lay) rid r*))]))

;; 切换某 dock 的 active 成员（不改结构）；供 prompt（status↔input）等复用。
(define (region-activate! w rid name)
  (region-show (region-set-active w rid name) rid))

;;; ---------- 命令 ----------

(define (h-region-cycle ctx w args)
  (define rid (car args))
  (define r (region-ref w rid))
  (cond
    [(not r) #f]
    [else
     (define ms (region-members r))
     (define cur (region-active r))
     (define i (or (for/first ([m (in-list ms)] [i (in-naturals)] #:when (equal? m cur)) i) 0))
     (define next (list-ref ms (modulo (add1 i) (length ms))))
     (cons (region-show (region-set-active w rid next) rid) '())]))

(define (h-region-activate ctx w args)
  (define rid (car args))
  (define name (cadr args))
  (cond [(not (region-ref w rid)) #f]
        [else (cons (region-show (region-set-active w rid name) rid) '())]))

(define (h-region-toggle ctx w args)
  (define rid (car args))
  (define r (region-ref w rid))
  (cond
    [(not r) #f]
    [else (cons (if (region-wid r) (region-hide w rid) (region-show w rid)) '())]))

(define (h-region-focus ctx w args)
  (define rid (car args))
  (define w* (region-show w rid))
  (define r (region-ref w* rid))
  (cond [(not (and r (region-wid r))) #f]
        [else (cons (world-set-focus w* (region-wid r)) '())]))

(define region-commands
  (make-command-registry
   (list (cons 'region-cycle h-region-cycle)
         (cons 'region-activate h-region-activate)
         (cons 'region-toggle h-region-toggle)
         (cons 'region-focus h-region-focus))))
