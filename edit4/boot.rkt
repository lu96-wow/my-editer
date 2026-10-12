#lang racket

;;; edit4/boot.rkt —— 初始 World（底盘）
;;;
;;; 只负责「造一个能跑的 World」：文档 + 面板 + 布局底盘 + 文件树 + 面板槽。
;;; 与装配（Environment）分开：boot 不 require 任何 view/命令，只碰值。

(provide boot)

(require "core/world.rkt"
         "content/model.rkt" "content/tree.rkt"
         "layout.rkt")

;; boot：侧栏(树 / 文档管理 互斥) | 主区(编辑器 / 状态栏)。
;;   id 2 = 侧栏槽（固定 28），id 0 = 编辑器（弹性），id 1 = 状态栏（固定 1 行）。
;;   面板文档：*tree* / *buffers* / *input* / *status*。
(define (boot #:text [text ""] #:name [name "*scratch*"] #:path [path #f]
              #:root [root (current-directory)])
  (define c0 (content-blank))
  (define-values (c1 _did-ed vid-ed) (content-add-doc! c0 text 60 22 name path))
  (define-values (c2 _did-tr vid-tr) (content-add-panel! c1 "*tree*" 28 24))
  (define-values (c2b _did-bu _vid-bu) (content-add-panel! c2 "*buffers*" 28 24))
  (define-values (c2c _did-in _vid-in) (content-add-panel! c2b "*input*" 60 1))
  (define-values (c2d _did-lg _vid-lg) (content-add-panel! c2c "*log*" 60 6))
  (define-values (c3 _did-st vid-st) (content-add-panel! c2d "*status*" 60 1))
  (define right (split 'v 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                                  (child (size 1 #f) (leaf 1 (cons 1 1))))))
  (define chassis (split 'h 1 (list (child (size 28 #f) (leaf 2 (cons 1 1)))
                                    (child (size 1 #t) right))))
  ;; 侧栏槽（窗口 2 显示 *tree* / *buffers*）；日志槽默认隐藏（C-l 显示，贴主区底部）。
  (define regions
    (hash 'sidebar (region 'left 28 (list "*tree*" "*buffers*") "*tree*" 'root 2)
          'log     (region 'bottom 6 (list "*log*") "*log*" 'main #f)))
  (define c (content-set-regions c3 regions))
  (define c* (content-bind (content-bind (content-bind c 0 vid-ed) 1 vid-st) 2 vid-tr))
  (refresh-tree! (make-world #:layout chassis #:focus 0 #:content c*) #:root root))
