#lang info

;;; 安装 / 卸载脚本不是 Racket 模块，不参与编译。
;;; （多 collection 包会把每个一级子目录当作 collection，这里显式忽略。）

(define name "edit install scripts")
(define compile-omit-paths 'all)
