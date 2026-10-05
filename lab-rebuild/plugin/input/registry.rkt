#lang racket

(require "api.rkt"
         "auto-pair.rkt"
         "../../config/plugins.rkt")

;;; lab-rebuild/plugin/input/registry.rkt —— 内置输入插件**目录** + 启用集
;;;
;;; 目录 = 有哪些；启用集 = config/plugins.rkt 选哪些（只给名字，这里解析）。

(provide input-plugin-catalog input-plugins-by-names enabled-input-plugins)

(define input-plugin-catalog
  (list auto-pair-plugin))

(define (input-plugins-by-names names)
  (for/list ([n (in-list names)]
             #:when (for/or ([p (in-list input-plugin-catalog)])
                      (eq? n (input-plugin-name p))))
    (for/first ([p (in-list input-plugin-catalog)] #:when (eq? n (input-plugin-name p))) p)))

(define enabled-input-plugins (input-plugins-by-names input-plugin-names))
