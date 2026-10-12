#lang racket

;;; edit4/boot.rkt —— 初始 World（底盘）
;;;
;;; 只负责「造一个能跑的 World」：文档 + 面板 + 布局底盘 + 文件树。
;;; 与装配（Environment）分开：boot 不 require 任何 view/命令，只碰值。

(provide boot)

(require "core/world.rkt"
         "content/model.rkt" "content/tree.rkt"
         "layout.rkt")

;; boot：侧栏(树) | 主区(编辑器 / 状态栏)。
;;   id 2 = 树（固定 28），id 0 = 编辑器（弹性），id 1 = 状态栏（固定 1 行）。
(define (boot #:text [text ""] #:name [name "*scratch*"] #:path [path #f]
              #:root [root (current-directory)])
  (define c0 (content-blank))
  (define-values (c1 _did-ed vid-ed) (content-add-doc! c0 text 60 22 name path))
  (define-values (c2 _did-tr vid-tr) (content-add-panel! c1 "*tree*" 28 24))
  (define-values (c3 _did-st vid-st) (content-add-panel! c2 "*status*" 60 1))
  (define right (split 'v 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                                  (child (size 1 #f) (leaf 1 (cons 1 1))))))
  (define chassis (split 'h 1 (list (child (size 28 #f) (leaf 2 (cons 1 1)))
                                    (child (size 1 #t) right))))
  (define c (content-bind (content-bind (content-bind c3 0 vid-ed) 1 vid-st) 2 vid-tr))
  (refresh-tree! (make-world #:layout chassis #:focus 0 #:content c) #:root root))
