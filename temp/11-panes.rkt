#lang racket
;;; 11 —— 用 panel + pane 拼一帧（layout × core × core-render 接口配合）
;;;
;;; 运行：racket temp/11-panes.rkt
;;;
;;; 链条：
;;;   buffer/view（core）
;;;     → panel（layout-base：rect 几何 + owner + borders/deep/face）
;;;     → panels->entries      → display-entry（view + 内容区原点 + deep）
;;;     → panels->decorations  → 边框 pane
;;;     → render-display       → composition（view 内容 pane ⊕ 边框 pane，按 deep 遮挡）
;;;     → screen->string       → 纯文本一帧（无需 tty / 后端）
;;;
;;; 尺寸不变量：view 的 w/h 必须等于 panel 的**内容区**尺寸（panel-content），
;;; 由宿主在布局变化时 view-resize! 落进 viewport。

(require "../core/editor.rkt"
         "../edit-tui/layout-base/main.rkt"
         "../edit-tui/core-render/main.rkt")

;;; ---------- 内容：三份文档 / 三个 view ----------

(define tree-b (make-buffer "src/\n  main.rkt\n  util.rkt\n  pane.rkt\nREADME.md" "*tree*"))
(define doc-b  (make-buffer "(define (f x)\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define pop-b  (make-buffer "popup\non top\n" "*popup*"))

(define tree-v (buffer-add-view! tree-b 18 10 #:line-numbers? #t))
(define doc-v  (buffer-add-view! doc-b  51 10 #:line-numbers? #t))
(define pop-v  (buffer-add-view! pop-b  18 4))

;;; ---------- 布局：三块 panel（rect 含边框，内容区由 panel-content 算）----------
;;;
;;; tree 右边界 + doc 不画左边 → 中间只有一条分隔线（逐边模型，共享边由一侧声明）。

(define tree-p (make-panel 'tree  (rect 0 0 20 12)  '(up down left right)))
(define doc-p  (make-panel 'doc   (rect 20 0 52 12) '(up down right)))
(define pop-p  (make-panel 'popup (rect 30 2 22 6)  borders-all
                           #:deep 10 #:face 'float-border))

(define panels (list tree-p doc-p pop-p))

(define (node->view o)
  (case o [(tree) tree-v] [(doc) doc-v] [(popup) pop-v] [else #f]))

;; view 尺寸 = 内容区尺寸
(for ([p (in-list panels)])
  (define c (panel-content p))
  (define v (node->view (panel-owner p)))
  (when v (view-resize! v (rect-w c) (rect-h c))))

;;; ---------- 布局 → 渲染输入 ----------

(define entries (panels->entries panels node->view))
(define decorations (panels->decorations panels))

(define W 72) (define H 12)

(displayln "======== 全量一帧：view 内容 + 边框 ========")
(define frame (render-display entries doc-v W H decorations))
(displayln (screen->string frame))

;;; ---------- 增量：编辑 doc（screen-patch 只回差量）----------

(void (buffer-edit! doc-b doc-v (op-type ";; hi\n")))
(define-values (frame2 rends sels)
  (render-display-patch entries doc-v W H frame decorations))
(displayln "======== 编辑后（增量）========")
(displayln (screen->string frame2))
(printf "增量片：render=~a / selection=~a\n\n" (length rends) (length sels))

;;; ---------- 浮窗移动：换 rect → 重新算 entries / decorations ----------

(define pop-p2 (make-panel 'popup (rect 34 3 22 6) borders-all
                           #:deep 10 #:face 'float-border))
(define panels2 (list tree-p doc-p pop-p2))
(define entries2 (panels->entries panels2 node->view))
(define frame3 (render-display entries2 doc-v W H (panels->decorations panels2)))
(displayln "======== 浮窗右移（换 rect）========")
(displayln (screen->string frame3))

;;; ---------- 命中：deep 高的浮窗胜 ----------

(printf "panel-at (40,5) → owner = ~a\n" (panel-owner (panel-at panels2 40 5)))
(printf "panel-at (5,1)  → owner = ~a\n" (panel-owner (panel-at panels2 5 1)))
(printf "panel-at (25,1) → owner = ~a\n" (panel-owner (panel-at panels2 25 1)))

;;; 说明：上面每一步的 rends / sels 就是 `piece`（row col text attr），
;;; 交给 edit-tui/core-render 的 render-pieces 即得 tui 序列（见 README 宿主用法）。
