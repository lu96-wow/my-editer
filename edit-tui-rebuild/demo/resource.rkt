#lang racket

;;; edit-tui/demo/resource.rkt —— 资源列表面板 + 显式 placement
;;;
;;;   racket edit-tui/demo/resource.rkt
;;;
;;; 左侧 *resources* 面板本身也是 buffer：
;;;   main.rkt               绿色 = document
;;;     view:1  region:1 *  [focus]
;;;     view:2  detached
;;;   other.txt              蓝色 = view（缩进在 document 下）
;;;
;;; 资源面板键：
;;;   ↑↓ Home End   移动选中行
;;;   Enter         document 行：折叠/展开；view 行：打开（attached 聚焦 / detached 进入 placement）
;;;   Tab           折叠 / 展开 document
;;;   v             给选中 document 新建 detached view
;;;   n             新建 scratch document + detached view
;;;   r             选中 view -> placement
;;;   d             把选中 view 从 panel detach
;;;   c             销毁选中 view（document 保留）
;;;   Esc           取消 placement
;;;
;;; placement（显式选目标 panel）：
;;;   1. 资源面板里 r；
;;;   2. 用鼠标 / M-方向把焦点移到目标 panel；
;;;   3. C-x C-p 提交：替换目标 panel 的 active view，旧 view 被 detach 保留。
;;;
;;; 其它：C-w C-w close view，M-w close panel，C-x C-k close doc，
;;; C-x C-s save，C-q quit。

(require "../theme/main.rkt"
         "../base/id.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../chrome/slot.rkt"
         "../plugins/resource/plugin.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define d1 (doc-id 1))
(define v1 (view-id 1))
(define editor-rid (region-id 1))
(define resource-rid (region-id 2))
(define chrome-rid (region-id 3))

(define engine (make-engine))
(void (engine-create-doc! engine d1 "main.rkt"
                          "Resource panel demo.\n\nM-← focus resources; then Tab/v/n/r/d/c.\nSelect a view, r, focus target panel, C-x C-p.\n"))
(void (engine-create-view! engine v1 d1))
(define baseline (engine-view-doc-version (make-engine-view engine) d1))

(define ws0
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws d1 (make-doc-meta "main.rkt"
                                                     #:path "main.rkt"
                                                     #:saved-version baseline))]
         [ws (workspace-add-view ws v1 (view-meta d1 (hash)))]
         [ws (workspace-add-region ws editor-rid
                                   (region editor-rid (list (view-member v1)) v1 'editor))])
    ws))

(define s0 (make-state #:workspace ws0 #:ids (make-id-counter 2 2 4 1)))
(define s1 (install-resource-panel! engine s0 resource-rid))
(define s2 (install-chrome! engine s1 chrome-rid))

(define lay
  (make-split
   'tb
   (list
    (make-split 'lr
                (list (make-leaf resource-rid (flex 1 #:max 32))
                      (make-leaf editor-rid (flex 3)))
                (flex 1))
    (make-leaf chrome-rid (fixed 1) #:borders '()))
   (flex 1)))

(define s3 (state-set-workspace s2
                                (struct-copy workspace (state-workspace s2) [layout lay])))
(define state
  (state-set-focus
   (state-chrome* s3 (λ (c) (chrome-set-message c "resources demo")))
   v1))

(module+ main
  (run-app default-env state engine))
