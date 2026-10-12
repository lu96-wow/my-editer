#lang racket

;;; edit4/plugins/catalog.rkt —— 插件目录（名字 → 实现）
;;;
;;; 列表顺序 = 装配 / 层叠顺序（decor 叠加顺序、命令覆盖顺序、键表覆盖顺序）。
;;; config/plugins.rkt 只给名字，本文件负责解析成实现。加一个插件 = 写一个 plugin 值并放进目录。

(provide plugin-catalog plugins-by-names)

(require "../plugin.rkt"
         "syntax.rkt" "words.rkt" "brackets.rkt" "auto-pair.rkt"
         "demo.rkt" "async-demo.rkt")

(define plugin-catalog
  (list syntax-plugin
        words-plugin
        bracket-plugin
        auto-pair-plugin
        demo-plugin
        async-demo-plugin))

;; 名字 → 实现；未知名字直接报错（配置拼错不静默）。
(define (plugins-by-names names)
  (for/list ([n (in-list names)])
    (or (for/first ([p (in-list plugin-catalog)] #:when (eq? n (plugin-name p))) p)
        (error 'plugins-by-names "未知插件名: ~a（可用: ~a）"
               n (map plugin-name plugin-catalog)))))
