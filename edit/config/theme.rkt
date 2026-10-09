#lang racket

;;; edit/config/theme.rkt —— 选哪套配色（**只改下面这一行 require**）
;;;
;;; 只 require 一套；其余方案不会被加载 / 实例化（不占内存）。
;;; 换主题：把路径和方案名改成 theme/schemes/ 下的另一套，例如
;;;   (require (rename-in "../theme/schemes/nord.rkt" [nord active-scheme]))

(require (rename-in "../theme/schemes/tokyo-night.rkt" [tokyo-night active-scheme]))

(provide active-scheme)
