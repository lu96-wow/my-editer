#lang racket

;;; edit-tui-rebuild/demo/filetree.rkt —— 文件树面板
;;;
;;;   racket edit-tui-rebuild/demo/filetree.rkt [root]
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
;;; C-d       删除文件
;;; C-x C-p   placement 提交到当前/点击的 panel

(require "../../edit-tui/theme/main.rkt"
         "../base/id.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../bootstrap/chrome.rkt"
         "../bootstrap/filetree-panel.rkt"
         "../bootstrap/defaults.rkt"
         "../runtime/run.rkt")

(define args (current-command-line-arguments))
(define root
  (if (positive? (vector-length args))
      (vector-ref args 0)
      (path->string (current-directory))))

(define filetree-rid (region-id 1))
(define chrome-rid (region-id 2))

(define engine (make-engine))
(define s0 (make-state #:ids (make-id-counter 1 1 3 1)))
(define s1 (install-filetree-panel! engine s0 filetree-rid root))
(define s2 (install-chrome! engine s1 chrome-rid))
(define ftv (filetree-panel-view s2))

(define lay
  (make-split 'tb
              (list (make-leaf filetree-rid (flex 1))
                    (make-leaf chrome-rid (fixed 1) #:borders '()))
              (flex 1)))
(define s3 (state-set-workspace s2
                                (struct-copy workspace (state-workspace s2) [layout lay])))
(define state
  (state-set-focus
   (state-chrome* s3 (λ (c) (chrome-set-message c "filetree demo")))
   ftv))

(module+ main
  (run-app default-env state engine))
