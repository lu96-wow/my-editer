#lang racket

;;; edit-tui-rebuild/demo/filetree.rkt —— 文件树面板
;;;
;;;   racket edit-tui-rebuild/demo/filetree.rkt [root]
;;;
;;; 布局：文件树占满左侧高度，上/下/左边框关闭，仅保留右侧分隔边。
;;; 右侧是 editor + status；打开文件后进入 placement，点击 editor 或 C-x C-p 放入。
;;;
;;; 根目录第一行显示完整路径。
;;; 目录缩进 2 空格/层；文件绿色 = 已在 workspace 中打开。
;;;
;;; Enter:
;;;   目录 -> 展开/折叠
;;;   文件 -> 打开；已有 editor panel 时进入 placement（自己选 panel）；
;;;           没有 editor panel 时自动创建并放入。
;;; C-n f     创建文件
;;; C-n C-n f 创建文件夹
;;; C-d       删除文件（input 栏 y/n 确认）
;;; C-x C-p   placement 提交到当前/点击的 panel
;;; C-b       显示 / 隐藏文件树面板
;;; C-w ←→↑↓  在编辑区拆分

(require "../../edit-tui/theme/main.rkt"
         "../base/id.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../bootstrap/chrome.rkt"
         "../bootstrap/filetree-plugin.rkt"
         "../bootstrap/defaults.rkt"
         "../runtime/run.rkt")

(define args (current-command-line-arguments))
(define root
  (if (positive? (vector-length args))
      (vector-ref args 0)
      (path->string (current-directory))))

(define filetree-rid (region-id 1))
(define editor-rid (region-id 2))
(define chrome-rid (region-id 3))

(define engine (make-engine))
(define s0 (make-state #:ids (make-id-counter 1 1 4 1)))
(define s1 (install-filetree-panel! engine s0 filetree-rid root))
(define s2 (install-chrome! engine s1 chrome-rid))
(define ftv (filetree-panel-view s2))

;; 文件树占满左侧高度；上/下/左无边框，只保留右侧分隔边。
(define s2b
  (state-workspace*
   s2
   (λ (ws)
     (workspace-add-region ws editor-rid
                           (region editor-rid '() #f 'editor)))))
(define lay
  (make-split
   'lr
   (list (make-leaf filetree-rid (fixed 28) #:borders '(right))
         (make-split 'tb
                     (list (make-leaf editor-rid (flex 1))
                           (make-leaf chrome-rid (fixed 1) #:borders '()))
                     (flex 1)))
   (flex 1)))
(define s3 (state-set-workspace s2b
                                (struct-copy workspace (state-workspace s2b) [layout lay])))
(define state
  (state-set-focus
   (state-chrome* s3 (λ (c) (chrome-set-message c "filetree demo")))
   ftv))

(module+ main
  (run-app default-env state engine))
