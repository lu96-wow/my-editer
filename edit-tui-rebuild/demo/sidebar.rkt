#lang racket

;;; edit-tui-rebuild/demo/sidebar.rkt —— 文件树 + 资源列表共用一个面板位置
;;;
;;;   racket edit-tui-rebuild/demo/sidebar.rkt [root]
;;;
;;; 左侧只有一个 region（sidebar），成员是：
;;;
;;;   view 1 = *filetree*   文件树
;;;   view 2 = *resources*  资源列表
;;;
;;; active 决定显示哪一个，**Tab 切换**（全局 switch-member 命令）：
;;;   · 切到哪个就聚焦哪个；
;;;   · 不 active 的那个不重建 buffer（文件树被挡住时不扫盘）；
;;;   · 状态栏 role 'slot 的 switch? = #f，所以 Tab 不会把状态栏切成输入栏。
;;;
;;; 布局：左侧 sidebar（固定 30 列，只保留右边框）+ 右侧 editor/status。
;;;
;;; 键位：
;;;   Tab            在文件树 / 资源列表之间切换
;;;   ↑↓ Home End    在面板内移动；鼠标点击也能聚焦 + 落点
;;;   Enter          文件树：展开目录 / 打开文件；资源列表：折叠展开 / 打开 view
;;;   C-b            显示 / 隐藏整个 sidebar
;;;   C-n f / C-d    文件树：建文件 / 删文件（y/n 确认）
;;;   v n r d c      资源列表：新 view / 新 doc / placement / detach / 关 view
;;;   C-x C-p        提交 placement 到当前 panel
;;;   C-w ←→↑↓       编辑区拆分；C-w C-w 关 view；M-方向 移动焦点
;;;   C-q            退出

(require "../../edit-tui/theme/main.rkt"
         "../base/id.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../chrome/slot.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/resource/plugin.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define args (current-command-line-arguments))
(define root
  (if (positive? (vector-length args))
      (vector-ref args 0)
      (path->string (current-directory))))

;; 一个 region，两个面板共用。
(define sidebar-rid (region-id 1))
(define editor-rid (region-id 2))
(define chrome-rid (region-id 3))

(define d1 (doc-id 1))
(define v1 (view-id 1))

(define engine (make-engine))
(void (engine-create-doc! engine d1 "scratch.rkt"
                          "Sidebar demo: filetree + resources share one panel.\n\nTab switches between them.\nC-b hides the whole sidebar.\n"))
(void (engine-create-view! engine v1 d1))

(define ws0
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc
              ws d1 (make-doc-meta "scratch.rkt" #:path "scratch.rkt"
                                   #:saved-version
                                   (engine-view-doc-version (make-engine-view engine) d1)))]
         [ws (workspace-add-view ws v1 (view-meta d1 (hash)))]
         [ws (workspace-add-region ws editor-rid
                                   (region editor-rid (list (view-member v1)) v1 'editor))])
    ws))

(define s0 (make-state #:workspace ws0 #:ids (make-id-counter 2 2 4 1)))

;; 两次安装传同一个 region-id -> 同一个 region 的两个成员（role 由第一次决定）。
(define s1 (install-filetree-panel! engine s0 sidebar-rid root))
(define s2 (install-resource-panel! engine s1 sidebar-rid))
(define s3 (install-chrome! engine s2 chrome-rid))
(define ftv (filetree-panel-view s3))

(define lay
  (make-split
   'lr
   (list (make-leaf sidebar-rid (fixed 30) #:borders '(right))
         (make-split 'tb
                     (list (make-leaf editor-rid (flex 1))
                           (make-leaf chrome-rid (fixed 1) #:borders '()))
                     (flex 1)))
   (flex 1)))

(define s5 (state-set-workspace s3
                                (struct-copy workspace (state-workspace s3) [layout lay])))

;; 初始显示文件树（后装的资源列表是 active，切回文件树演示 Tab 的初值）。
(define s6 (state-workspace* s5 (λ (ws) (workspace-attach-view ws sidebar-rid ftv))))

(define state
  (state-set-focus
   (state-chrome*
    s6
    (λ (c) (chrome-set-message c "Tab: filetree <-> resources")))
   ftv))

(module+ main
  (run-app default-env state engine))
