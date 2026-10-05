#lang racket

(require "edit.rkt"
         "focus.rkt"
         "app.rkt"
         "readonly.rkt"
         "tree.rkt"
         "bufs.rkt"
         "modal.rkt")

;;; lab/app/keys/main.rkt —— 默认命令表汇总
;;;
;;; 装配点（app.rkt）只 require 这里；下面的表各自独立成文件。

(provide (all-from-out "edit.rkt")
         (all-from-out "focus.rkt")
         (all-from-out "app.rkt")
         (all-from-out "readonly.rkt")
         (all-from-out "tree.rkt")
         (all-from-out "bufs.rkt")
         (all-from-out "modal.rkt"))
