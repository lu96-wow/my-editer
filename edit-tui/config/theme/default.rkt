#lang racket

;;; edit-tui/config/theme/default.rkt —— 默认主题数据（纯）
;;;
;;; 只产出 (name style) 表，不 require tui、不在 require 时安装。
;;; 安装由 host/render/theme.rkt 的 install-theme! 完成。
;;; 换主题 = 换这个模块里的表。

(require "../../core/face/api.rkt")

(provide base-theme
         frame-theme
         chrome-theme
         syntax-theme
         word-color-theme
         bracket-theme
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
   (list 'float-border   (style (rgb 190 150 240) #f '()))
   ;; bilingual：source / mirror panel 边框 + mirror 文本底色
   (list 'bilingual-source-border (style (rgb 120 200 200) #f '()))
   (list 'bilingual-mirror-border (style (rgb 190 150 240) #f '()))
   (list 'bilingual-pair-border   (style (rgb 160 180 230) #f '()))))

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
   (list 'docs-body  (style (rgb 200 200 200) #f '()))
   ;; bilingual mirror 文本（derived view 的整行 face）
   (list 'bilingual-mirror-line (style (rgb 225 220 240) (rgb 34 30 44) '()))))

;; 语法高亮：role 名由 lang/racket/color 产出。
(define syntax-theme
  (list
   (list 'syntax-keyword-def     (style (rgb 120 180 240) #f '()))
   (list 'syntax-keyword-control (style (rgb 230 150 180) #f '()))
   (list 'syntax-keyword-macro   (style (rgb 190 150 240) #f '()))
   (list 'syntax-keyword-binding (style (rgb 235 190 110) #f '()))
   (list 'syntax-keyword-module  (style (rgb 120 200 200) #f '()))
   (list 'syntax-string          (style (rgb 190 220 140) #f '()))
   (list 'syntax-comment         (style (rgb 120 120 130) #f '(italic)))
   (list 'syntax-number          (style (rgb 200 170 240) #f '()))))

;; 同词着色：12 色粉彩，同词同色。
(define word-color-theme
  (for/list ([i (in-range 12)]
             [c (in-list '((230 194 158) (216 204 152) (184 210 160) (162 212 172)
                           (152 214 202) (142 206 226) (150 196 236) (166 182 236)
                           (196 172 234) (206 172 226) (188 178 214) (178 198 214)))])
    (list (string->symbol (format "word-color-~a" i))
          (style (apply rgb c) #f '()))))

;; 括号深度背景：8 层循环使用，颜色来自 edit4 的低饱和底色。
(define bracket-theme
  (for/list ([i (in-range 8)]
             [c (in-list '((36 40 58) (28 47 49) (48 46 30) (30 49 40)
                           (42 34 58) (34 44 58) (38 48 34) (44 38 54)))])
    (list (string->symbol (format "bracket-depth-~a" i))
          (style #f (apply rgb c) '()))))

;; overlay（光标 / 选区）
(define overlay-theme
  (list
   (list 'cursor    (style #f #f '(reverse)))
   (list 'selection (style #f (rgb 60 70 90) '()))))

;; 扁平表：交给 host 安装
(define default-theme
  (append base-theme frame-theme chrome-theme
          syntax-theme word-color-theme
          bracket-theme overlay-theme))
