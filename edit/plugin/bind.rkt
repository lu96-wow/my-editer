#lang racket

;;; edit/plugin/bind.rkt —— 「把 face 插件绑到文档」的规则
;;;
;;; 插件层负责构造这条规则，装配层把它放进 session 的 rules（打开文件时执行）。
;;; 于是 document/rules.rkt 保持纯机制，document 层不 import 任何插件实现/目录。

(require "../document/rules.rkt"
         "../session.rkt"
         "registry.rkt")

(provide face-plugin-rule)

;; plugins : (listof face-plugin)  已解析、已按目录排序的启用集
(define (face-plugin-rule plugins)
  (rule 'face-plugins
        (lambda (path) #t)
        (lambda (s did path)
          (session-doc-bind-plugins
           s did
           (plugins-for plugins path (session-document-string s did))))))
