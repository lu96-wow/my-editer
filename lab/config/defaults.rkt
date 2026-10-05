#lang racket

(require "../base/layout/main.rkt")

;;; lab-rebuild/config/defaults.rkt —— 应用可配置默认值（纯数据）
;;;
;;; 这里只放「应用装配时读一次」的可调参数，不放算法内在常量
;;; （min-pane-width / split-gap 属于布局算法，留在 base/layout）。
;;; 布局的默认尺寸从 base/layout 重导出，保证「一个数只定义一处」。

(provide (all-from-out "../base/layout/main.rkt")
         default-editor-width default-editor-height
         plugin-worker-count plugin-history-bound
         initial-left-panel)

;; 初始编辑格尺寸（新建 view 时用；之后 resize 会覆盖）
(define default-editor-width 80)
(define default-editor-height 24)

;; 左栏初始显示：'tree | 'bufs
(define initial-left-panel 'tree)

;; 属性插件运行时
(define plugin-worker-count 2)      ; 后台 place 进程数
(define plugin-history-bound 64)    ; 每个 did 保留的版本 token 数
