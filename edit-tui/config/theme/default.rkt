#lang racket

;;; edit-tui-rebuild/config/theme/default.rkt —— 默认主题
;;;
;;; 配置层：多个小表
;;; 安装层：append 成一个扁平表，再 define-theme!
;;;
;;; require 即安装。
;;; 换主题 = 换 require 的 config/theme/*.rkt。

(require "../../render/theme.rkt")

(provide base-theme
         frame-theme
         chrome-theme
         overlay-theme
         default-theme)

;; 基础文本 / 行号 / 属性
(define base-theme
  (list
   (list 'fg-default  (style #f #f '()))
   (list 'bg-default  (style #f #f '()))
   (list 'fg-dim      (style (rgb 120 120 130) #f '()))
   (list 'line-number (style (rgb 120 120 130) #f '()))
   (list 'bold        (style #f #f '(bold)))
   (list 'dim         (style #f #f '(dim)))
   (list 'italic      (style #f #f '(italic)))
   (list 'underline   (style #f #f '(underline)))
   (list 'blink       (style #f #f '(blink)))))

;; 边框
(define frame-theme
  (list
   (list 'window-border  (style (rgb 105 112 128) #f '()))
   ;; 焦点面板的边框（projection 用空 panel + 更高 weight 叠在边框格上）
   (list 'focused-border (style (rgb 120 180 240) #f '()))
   (list 'float-border   (style (rgb 190 150 240) #f '()))))

;; chrome / 资源面板
(define chrome-theme
  (list
   (list 'status-bar        (style (rgb 225 225 225) (rgb 40 44 52) '()))
   ;; filetree：根 / 目录 / 已打开文件 / 普通文件
   (list 'filetree-root     (style (rgb 200 200 200) #f '(bold)))
   (list 'filetree-dir      (style (rgb 120 180 240) #f '(bold)))
   (list 'filetree-open     (style (rgb 120 210 130) #f '()))
   (list 'filetree-file     (style (rgb 200 200 200) #f '()))
   (list 'status-mode       (style (rgb 120 210 130) #f '(bold)))
   (list 'status-dirty      (style (rgb 230 160 90) #f '(bold)))
   (list 'message           (style (rgb 230 160 90) #f '()))
   (list 'input             (style #f #f '()))
   ;; 输入栏 prompt 前缀（buffer 里同时标 readonly）
   (list 'input-prompt      (style (rgb 140 160 190) #f '()))
   (list 'resource-document (style (rgb 200 200 200) #f '()))
   (list 'resource-view     (style (rgb 140 160 190) #f '()))
   (list 'resource-focus    (style (rgb 120 210 130) #f '(bold)))
   (list 'resource-pending  (style (rgb 230 160 90) #f '(bold)))
   ;; completion popup
   (list 'completion          (style (rgb 200 200 200) #f '()))
   (list 'completion-selected (style (rgb 10 10 10) (rgb 120 180 240) '(bold)))
   ;; docs panel
   (list 'docs-title (style (rgb 120 210 130) #f '(bold)))
   (list 'docs-dim   (style (rgb 140 150 165) #f '()))
   (list 'docs-body  (style (rgb 200 200 200) #f '()))))

;; overlay（光标 / 选区）
(define overlay-theme
  (list
   (list 'cursor    (style #f #f '(reverse)))
   (list 'selection (style #f (rgb 60 70 90) '()))))

;; 安装层：扁平表
(define default-theme
  (append base-theme frame-theme chrome-theme overlay-theme))

(define-theme! default-theme)
