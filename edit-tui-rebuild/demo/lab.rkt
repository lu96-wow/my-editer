#lang racket

;;; edit-tui-rebuild/demo/lab.rkt —— 高亮 + 补全 + 文档面板
;;;
;;;   racket edit-tui-rebuild/demo/lab.rkt [file]
;;;
;;; 这一版把三个“写代码用”的插件装到一起（plugins/builtin.rkt 的 editor-env）：
;;;
;;;   highlight   语法高亮：写前景层 'syntax-fg（后台算，set-face-layer-effect）
;;;   depth-bg    括号深度底色：写背景层 'depth-bg（同一个后台 worker，按提交顺序执行）
;;;   completion  M-/ 原地补全，再按循环候选（replace-range-effect）
;;;   docs        M-h 在右侧面板看光标处的文档（after-nav 自动刷新）
;;;
;;; 它们都不需要改框架：全部是 plugin 数据（hook / command / rule / mode / panel）。
;;;
;;; 键位：
;;;   C-c /          补全（重复按循环候选）
;;;   C-c h          文档面板开关（光标处标识符；面板在下方面板区，固定 8 行，手动关闭）
;;;   ↑↓←→ Home End  移动；Enter / Backspace / Delete 编辑
;;;   C-z / C-y      undo / redo
;;;   C-w ←→↑↓       拆出一个空窗口；C-w C-w 关 view
;;;   M-方向         焦点移动；Tab 切换同一位置的多个面板
;;;   C-b            侧栏（文件树 / 资源列表）显隐
;;;   C-x C-s / C-x C-f / C-x C-k   保存 / 打开 / 关闭文档
;;;   C-q            退出

(require "../../edit-tui/theme/main.rkt"
         "../base/id.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../effects/panel.rkt"
         "../chrome/slot.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/resource/plugin.rkt"
         "../plugins/docs/plugin.rkt"
         "../plugins/completion/plugin.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define args (current-command-line-arguments))
(define root
  (if (positive? (vector-length args))
      (path->string (simplify-path (path->complete-path (vector-ref args 0))))
      (path->string (current-directory))))

(define sidebar-rid (region-id 1))
(define editor-rid (region-id 2))
(define docs-rid (region-id 3))
(define chrome-rid (region-id 4))
(define completion-rid (region-id 5))

(define sample
  (string-join
   '(";; lab.rkt —— 高亮 / 补全 / 文档 演示"
     ";;"
     ";; C-c /  在光标处补全（再按换下一个候选）"
     ";; C-c h  看光标处标识符的文档（下方固定高度面板）"
     ""
     "(define (square x)"
     "  (* x x))"
     ""
     "(define (sum-of-squares a b)"
     "  (+ (square a) (square b)))"
     ""
     "(define (main)"
     "  (let ([xs (list 1 2 3 4 5)])"
     "    (map square xs)))")
   "\n"))

(define engine (make-engine))

;; 先建“用户文档”（id 从 1 开始），再装面板 —— 否则面板会先占掉 doc/view 1，
;; 用户文档的 id 就跟面板撞了（点哪都落到面板上 / 只能点到行尾就是这么来的）。
(define did (doc-id 1))
(define vid (view-id 1))
(void (engine-create-doc! engine did "lab.rkt" sample))
(void (engine-create-view! engine vid did))

(define s0
  (make-state #:ids (make-id-counter 2 2 5 1)))
(define s1
  (state-workspace*
   s0
   (λ (ws)
     (let* ([ws (workspace-add-doc
                 ws did
                 (make-doc-meta "lab.rkt" #:path "lab.rkt"
                                #:saved-version
                                (engine-view-doc-version (make-engine-view engine) did)))]
            [ws (workspace-add-view ws vid (view-meta did (hash)))])
       (workspace-add-region ws editor-rid
                             (region editor-rid (list (view-member vid)) vid 'editor))))))

;; 侧栏：文件树 + 资源列表共用一块位置（Tab 切换）
(define s2 (install-filetree-panel! engine s1 sidebar-rid root))
(define s3 (install-resource-panel! engine s2 sidebar-rid))
;; 文档面板
(define s4 (install-docs-panel! engine s3 docs-rid))
;; 补全浮层（*completion* 文档 + region；不在 layout 树里，弹窗时才出现）
(define s4b (install-completion-popup! engine s4 completion-rid))
;; status/input 槽
(define s5 (install-chrome! engine s4b chrome-rid))
(define ftv (filetree-panel-view s5))

;; 布局：左侧 sidebar | 右侧 editor；status 一行；docs 在 status **下面**，固定高度。
(define lay
  (make-split
   'lr
   (list (make-leaf sidebar-rid (fixed 26) #:borders '(right))
         (make-split
          'tb
          (list (make-split
                 'tb
                 (list (make-leaf editor-rid (flex 1))
                       (make-leaf chrome-rid (fixed 1) #:borders '()))
                 (flex 1))
                (make-leaf docs-rid (fixed 8) #:borders '(up)))
          (flex 1)))
   (flex 1)))

(define s6 (state-set-workspace s5
                                (struct-copy workspace (state-workspace s5) [layout lay])))
;; 文档面板初始收起（M-h 打开）
(define s7 (state-workspace*
            s6
            (λ (ws) (struct-copy workspace ws
                                 [layout (tree-hide (workspace-layout ws) docs-rid)]))))
(define s8
  (state-set-focus
   (state-chrome*
    s7
    (λ (c) (chrome-set-message c "C-c / complete   C-c h docs   Tab switch sidebar")))
   vid))

;; 首帧前补 document-opened（让高亮插件给这个预先建好的文档上色）
(define state (startup! editor-env engine s8))

(module+ main
  (run-app editor-env state engine))
