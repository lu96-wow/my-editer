#lang racket

;;; layer  : bootstrap/commands
;;; effect : 无（纯 State：显隐 + 尺寸记忆 + 焦点回退）
;;;
;;; bootstrap/commands/layout.rkt —— 区域显隐的通用原语
;;;
;;; toggle-region! 把“隐藏 / 显示一个 region”收成一处：
;;;   · hide：记录当前内容尺寸，把 leaf 的 dim 改成 fixed（尺寸记忆），再隐藏；
;;;   · show：直接 tree-show（dim 已经是记忆的 fixed 值）；
;;;   · 焦点原本在该 region 里 -> 退到 region 外的第一个真实文档 view，否则 #f。
;;;
;;; 这样 filetree / docs / 未来的 sidebar 不需要各写一遍 width 记忆 / tree-hide /
;;; tree-show / 焦点回退。
;;;
;;; 返回值：(values state' visible? size)
;;;   state'   : 新 State
;;;   visible? : 切换后的可见性（region 不存在 -> #f）
;;;   size     : 内容尺寸（内容格，不含边框；region 不存在 -> #f）

(provide toggle-region!)

(require "../../base/id.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/layout.rkt"
         "../../projection/geometry.rkt"
         "util.rkt")

;; 焦点是不是属于这个 region（view 所在 region / region-id 本身）。
(define (focus-in-region? ws rid focus)
  (cond
    [(not focus) #f]
    [(region-id? focus) (equal? focus rid)]
    [(view-id? focus)
     (define reg (workspace-view-region ws focus))
     (and reg (equal? (region-key reg) rid))]
    [else #f]))

;; 该 region 之外的第一个 attached 真实文档 view。
(define (fallback-view-outside ws rid)
  (for/first ([(vid vm) (in-hash (workspace-views ws))]
              #:when
              (let ([reg (workspace-view-region ws vid)])
                (and reg
                     (not (equal? (region-key reg) rid))
                     (workspace-view-attached? ws vid)
                     (real-view? ws vm))))
    vid))

(define (region-dim-size layout rid)
  (define l (tree-find layout rid))
  (and l (dim-value (node-dim l))))

(define (toggle-region! state rid #:min [min 1] #:axis [axis #f])
  (define ws (state-workspace state))
  (define layout (workspace-layout ws))
  (define leaf (tree-find layout rid))
  (cond
    [(not leaf)
     (values state #f #f)]
    [else
     (define visible? (leaf-visible? leaf))
     (define area (window-area (state-window state)))
     (define ax (or axis (region-parent-axis layout rid) 'lr))
     (cond
       [visible?
        ;; hide：先量内容尺寸，写回 fixed，再隐藏。
        (define measured (or (region-content-size layout area rid ax)
                             (region-dim-size layout rid)
                             min))
        (define size (max min measured))
        (define layout* (tree-hide (tree-set-dim layout rid (fixed size)) rid))
        (define ws1 (struct-copy workspace ws [layout layout*]))
        (define focus (workspace-focus ws1))
        (define ws2
          (if (focus-in-region? ws1 rid focus)
              (workspace-set-focus* ws1 (fallback-view-outside ws1 rid) #:push? #f)
              ws1))
        (values (state-set-workspace state ws2) #f size)]
       [else
        ;; show：dim 已经是隐藏时记录的 fixed 值。
        (define layout* (tree-show layout rid))
        (define ws1 (struct-copy workspace ws [layout layout*]))
        (define size (or (region-content-size layout* area rid ax)
                         (region-dim-size layout* rid)
                         min))
        (values (state-set-workspace state ws1) #t size)])]))
