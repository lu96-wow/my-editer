#lang racket

(require racket/list
         "../core/view/frame.rkt"
         "../framework/slots.rkt" rackunit)

;;; layout-tree.rkt —— 树布局（参考实现）
;;;
;;; layout data = #f | (leaf id) | (vsplit top bottom ratio) | (hsplit left right ratio)
;;;
;;; 约定：split 之间预留 1 列/行的「分隔槽」（GUTTER），供 compose 插件画 | / - 边框。
;;; 无边框的 plain-compose 会把它留白（窗口之间隔一列），同样合理。

(provide tree-layout)

(struct leaf (id) #:transparent)
(struct vsplit (top bottom ratio) #:transparent)
(struct hsplit (left right ratio) #:transparent)

(define GUTTER 1)

(define (tree-rects f)
  (define lt (frame-layout f))
  (if lt
      (tree-geometry lt 0 0 (frame-cols f) (frame-rows f))
      (list (list (frame-active f) 0 0 (frame-cols f) (frame-rows f)))))

(define (tree-order f)
  (define lt (frame-layout f))
  (if lt (leaf-order lt) (list (frame-active f))))

(define (tree-split f dir)
  (define id (frame-active f))
  (define-values (f1 nid) (frame-add-window f))
  (define lt (frame-layout f1))
  (define node (make-node dir (leaf id) (leaf nid)))
  (define lt* (if lt (tree-replace lt id node) node))
  (frame-sync-sizes
   (struct-copy frame f1 [layout lt*])     ; active 不变（留在原窗口）
   (tree-geometry lt* 0 0 (frame-cols f1) (frame-rows f1))))

(define (tree-close f)
  (define id (frame-active f))
  (cond
    [(<= (frame-window-count f) 1) f]
    [else
     (define lt (frame-layout f))
     (define lt* (if lt (tree-remove lt id) #f))
     (define f1 (frame-remove-window f id))
     (define f2 (struct-copy frame f1 [layout lt*]))
     (define f3 (frame-set-active f2 (car (tree-order f2))))
     (frame-sync-sizes f3 (tree-rects f3))]))

(define tree-layout (layout tree-rects tree-order tree-split tree-close))

;;; ---------- 树几何 ----------

(define (make-node dir a b)
  (case dir
    [(vsplit) (vsplit a b 1/2)]
    [(hsplit) (hsplit a b 1/2)]
    [else (error 'tree-layout "unknown dir ~a" dir)]))

(define (tree-geometry tree x y w h)
  (cond
    [(leaf? tree) (list (list (leaf-id tree) x y w h))]
    [(vsplit? tree)
     (define-values (th gutter) (split-dir h (vsplit-ratio tree)))
     (append (tree-geometry (vsplit-top tree) x y w th)
             (tree-geometry (vsplit-bottom tree) x (+ y th gutter) w (- h th gutter)))]
    [(hsplit? tree)
     (define-values (lw gutter) (split-dir w (hsplit-ratio tree)))
     (append (tree-geometry (hsplit-left tree) x y lw h)
             (tree-geometry (hsplit-right tree) (+ x lw gutter) y (- w lw gutter) h))]
    [else (error 'tree-layout "bad layout ~a" tree)]))

;; 把 total 切成 first + gutter + rest：两个窗口至少各 1，空间不够时先缩分隔槽（可为 0），
;; 避免除出来的 first 让另一侧变成 0 宽。
(define (split-dir total ratio)
  (define gutter (min GUTTER (max 0 (- total 2))))
  (define usable (- total gutter))
  (define first (max 1 (min (- usable 1) (floor (* usable ratio)))))
  (values first gutter))

(define (leaf-order tree)
  (cond
    [(leaf? tree) (list (leaf-id tree))]
    [(vsplit? tree) (append (leaf-order (vsplit-top tree)) (leaf-order (vsplit-bottom tree)))]
    [(hsplit? tree) (append (leaf-order (hsplit-left tree)) (leaf-order (hsplit-right tree)))]
    [else (error 'tree-layout "bad layout ~a" tree)]))

(define (tree-replace tree id new)
  (cond
    [(leaf? tree) (if (= id (leaf-id tree)) new tree)]
    [(vsplit? tree)
     (vsplit (tree-replace (vsplit-top tree) id new)
             (tree-replace (vsplit-bottom tree) id new)
             (vsplit-ratio tree))]
    [(hsplit? tree)
     (hsplit (tree-replace (hsplit-left tree) id new)
             (tree-replace (hsplit-right tree) id new)
             (hsplit-ratio tree))]
    [else (error 'tree-layout "bad layout ~a" tree)]))

(define (tree-remove tree id)
  (cond
    [(leaf? tree) (if (= id (leaf-id tree)) #f tree)]
    [(vsplit? tree)
     (define t* (tree-remove (vsplit-top tree) id))
     (define b* (tree-remove (vsplit-bottom tree) id))
     (cond [(not t*) b*] [(not b*) t*] [else (vsplit t* b* (vsplit-ratio tree))])]
    [(hsplit? tree)
     (define l* (tree-remove (hsplit-left tree) id))
     (define r* (tree-remove (hsplit-right tree) id))
     (cond [(not l*) r*] [(not r*) l*] [else (hsplit l* r* (hsplit-ratio tree))])]
    [else (error 'tree-layout "bad layout ~a" tree)]))

;;; ---------- 测试 ----------

(module+ test
  (require "../core/text/buffer.rkt" "../core/view/window.rkt")
  (define b (buffer-open "hello\nworld"))
  (define f0 (frame-open b 3 11))

  (check-equal? ((layout-rects tree-layout) f0) (list (list 0 0 0 11 3)))
  (check-equal? ((layout-order tree-layout) f0) '(0))

  ;; hsplit：左右各 5，中间留 1 列分隔槽（列 5）
  (define f1 ((layout-split tree-layout) f0 'hsplit))
  (check-equal? (frame-window-count f1) 2)
  (check-equal? (frame-active f1) 0)                       ; 焦点留在原窗口
  (check-equal? ((layout-rects tree-layout) f1)
                (list (list 0 0 0 5 3) (list 1 6 0 5 3)))
  (check-equal? ((layout-order tree-layout) f1) '(0 1))
  ;; 新窗口 point 同原窗口（看到同一位置）
  (check-equal? (window-point (frame-window f1 1)) (window-point (frame-window f1 0)))

  ;; vsplit：上下各 1，中间留 1 行分隔槽（行 1）
  (define f2 ((layout-split tree-layout) f0 'vsplit))
  (check-equal? ((layout-rects tree-layout) f2)
                (list (list 0 0 0 11 1) (list 1 0 2 11 1)))

  ;; close：关 active(0)，塌缩回窗口 1
  (define f3 ((layout-close tree-layout) f1))
  (check-equal? (frame-window-count f3) 1)
  (check-equal? (frame-active f3) 1)

  ;; 窄窗口：空间不够时分隔槽缩为 0，另一侧不为 0 宽
  (define f4 ((layout-split tree-layout) (frame-open b 1 2) 'hsplit))
  (check-equal? ((layout-rects tree-layout) f4)
                (list (list 0 0 0 1 1) (list 1 1 0 1 1)))

  (displayln "layout-tree.rkt: all tests passed"))
