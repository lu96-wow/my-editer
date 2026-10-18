#lang racket

;;; edit-tui/test/toggle-region.rkt —— 通用 region 显隐 / 尺寸记忆 / 焦点回退
;;;
;;; 覆盖：
;;;   1. hide：记录内容尺寸 -> leaf.dim 变 fixed -> visible? = #f；
;;;   2. show：恢复同一 fixed 尺寸；
;;;   3. 焦点在 region 里 -> 退到 region 外的真实文档 view；
;;;   4. 没有其它真实 view -> 焦点变 #f；
;;;   5. region 不存在 -> state 不变，visible? / size = #f；
;;;   6. #:min 生效。

(require rackunit
         "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../bootstrap/commands/layout.rkt")

(define did1 (doc-id 1))
(define did2 (doc-id 2))
(define vid1 (view-id 1))
(define vid2 (view-id 2))
(define rid1 (region-id 1))
(define rid2 (region-id 2))

(define (make-case #:side-dim [side-dim (fixed 10)] #:focus [focus vid1])
  (define ws0
    (workspace-add-doc
     (workspace-add-doc (workspace-empty)
                        did1 (make-doc-meta "one"))
     did2 (make-doc-meta "two")))
  (define ws1 (workspace-add-view ws0 vid1 (view-meta did1 (hash))))
  (define ws2 (workspace-add-view ws1 vid2 (view-meta did2 (hash))))
  (define ws3 (workspace-add-region ws2 rid1
                                    (region rid1 (list (view-member vid1)) vid1 'editor)))
  (define ws4 (workspace-add-region ws3 rid2
                                    (region rid2 (list (view-member vid2)) vid2 'editor)))
  (define ws5
    (struct-copy workspace ws4
                 [layout (make-split 'lr
                                     (list (make-leaf rid1 side-dim #:borders '(right))
                                           (make-leaf rid2 (flex 1)))
                                     (flex 1))]
                 [focus focus]))
  (make-state #:window (make-window 24 80) #:workspace ws5))

(define s0 (make-case))
(define-values (s1 vis1 size1) (toggle-region! s0 rid1))
(check-false vis1)
(check-true (>= size1 10))
(check-false (tree-visible? (workspace-layout (state-workspace s1)) rid1))
(define leaf1 (tree-find (workspace-layout (state-workspace s1)) rid1))
(check-true (dim-fixed? (leaf-dim leaf1)))
(check-equal? (dim-value (leaf-dim leaf1)) size1)
;; 焦点退到 region 外的真实 view
(check-eq? (state-focus s1) vid2)
(check-eq? (state-focus s0) vid1)          ; 纯：旧 state 不变

;; show：同一尺寸
(define-values (s2 vis2 size2) (toggle-region! s1 rid1))
(check-true vis2)
(check-equal? size2 size1)
(check-true (tree-visible? (workspace-layout (state-workspace s2)) rid1))
(define leaf2 (tree-find (workspace-layout (state-workspace s2)) rid1))
(check-true (dim-fixed? (leaf-dim leaf2)))
(check-equal? (dim-value (leaf-dim leaf2)) size1)

;; 焦点是 region-id 时也能回退
(define s-focus-region (make-case #:focus rid1))
(define-values (s3 _v3 _z3) (toggle-region! s-focus-region rid1))
(check-eq? (state-focus s3) vid2)

;; 没有其它真实 view -> #f
(define s-only
  (let* ([ws (state-workspace (make-case))]
         [ws* (workspace-remove-view ws vid2)]
         [ws** (struct-copy workspace ws* [focus vid1])])
    (state-set-workspace (make-case) ws**)))
(define-values (s4 _v4 _z4) (toggle-region! s-only rid1))
(check-false (state-focus s4))

;; region 不存在
(define missing (region-id 99))
(define-values (s5 vis5 size5) (toggle-region! s0 missing))
(check-eq? s5 s0)
(check-false vis5)
(check-false size5)

;; #:min
(define s-narrow (make-case #:side-dim (fixed 3)))
(define-values (s6 v6 size6) (toggle-region! s-narrow rid1 #:min 20))
(check-false v6)
(check-equal? size6 20)
(define leaf6 (tree-find (workspace-layout (state-workspace s6)) rid1))
(check-equal? (dim-value (leaf-dim leaf6)) 20)

(displayln "edit-tui toggle-region: ok")
