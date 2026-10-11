#lang racket

;;; config/theme.rkt —— 主题调色板（**纯数据**，不 require 实现）
;;;
;;; 编辑器里所有样式都用**命名 face**（符号）：'window-border、'status-bar、'tree-dir …。
;;; 这里只做「名字 → style 值」的映射；把 style 翻成 ANSI 字节在 core/theme.rkt。
;;;
;;; 加 / 改一个样式 = 改这里的 palette 一行。配色沿用 edit 的 tree/state 方案。

(provide (struct-out style)
         rgb palette theme-ref)

;; style 值：fg / bg = #f（终端默认）| (rgb r g b) 真彩色 | 0..255 整数（256 色）；
;;           attrs = (listof 'bold | 'dim | 'italic | 'underline)。
(struct style (fg bg attrs) #:transparent)

(define (rgb r g b) (list 'rgb r g b))

(define palette
  (hash
   'default        (style #f #f '())
   'dim            (style (rgb 120 120 130) #f '())
   'bold           (style #f #f '(bold))
   'italic         (style #f #f '(italic))
   'underline      (style #f #f '(underline))
   'accent         (style (rgb 120 180 240) #f '())
   ;; 窗口 / 边框
   'window-border  (style (rgb 105 112 128) #f '())
   ;; 状态行 / 消息 / 输入
   'status-bar     (style (rgb 225 225 225) (rgb 40 44 52) '())   ; 状态行
   'status-mode    (style (rgb 120 210 130) #f '(bold))           ; 模式 / 文档名
   'status-dirty   (style (rgb 230 160 90) #f '(bold))            ; 未保存标记
   'message        (style (rgb 230 160 90) #f '())                ; 提示 / 错误
   'input          (style #f #f '())                              ; 输入行：不加颜色修饰
   'log            (style (rgb 235 188 110) #f '())               ; 日志行
   ;; 文件树
   'tree-dir       (style (rgb 120 180 240) #f '())               ; 目录：蓝
   'tree-file      (style (rgb 200 200 200) #f '())               ; 文件：灰白
   'tree-link      (style (rgb 120 200 200) #f '())               ; 符号链接：青
   'tree-hidden    (style (rgb 120 120 130) #f '())               ; 隐藏项：暗
   'tree-open      (style (rgb 120 210 130) #f '(bold))           ; 已打开：绿粗
   'tree-match     (style (rgb 220 190 120) #f '())               ; 查询命中：黄
   'tree-current   (style (rgb 20 20 20) (rgb 230 200 90) '())    ; 当前命中：黄底
   ;; 资源面板（buffers）
   'buf-current    (style (rgb 120 210 130) #f '(bold))           ; 当前文档
   'buf-file       (style (rgb 200 200 200) #f '())               ; 其它文档
   'buf-untitled   (style (rgb 170 170 170) #f '())               ; 无路径
   'buf-view       (style (rgb 140 160 190) #f '())               ; 视图行
   'buf-dirty      (style (rgb 230 160 90) #f '(bold))))          ; 脏文档

(define (theme-ref name) (hash-ref palette name #f))
