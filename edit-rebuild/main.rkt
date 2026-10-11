#lang racket

;;; edit-rebuild/main.rkt —— 可运行入口：编辑器核心 + 外部插件
;;;
;;;   racket edit-rebuild/main.rkt
;;;
;;; 核心（edit-rebuild）不认识任何具体插件；这里把启用的插件注入组装。

(require "core/app/app.rkt"
         "core/backend/tui.rkt"
         "plugins/catalog.rkt")

(provide main)

(define (main)
  (run-tui (app-session #:plugins enabled-plugins)))

(module+ main (main))
