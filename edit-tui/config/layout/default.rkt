#lang racket

;;; edit-tui-rebuild/config/layout/default.rkt —— 默认布局配置（具体 kind 规则）
;;;
;;; 这是 configuration，不是骨架：
;;;   · 骨架（layout/config.rkt）只定义 panel-rule / layout-config 的形状；
;;;   · 这里决定 editor / sidebar / status 各自能不能 split / hide / delete，
;;;     以及 min / max。
;;;
;;; 选择配置 = require 本模块，然后把得到的 config 传给 layout API
;;; （或放进 app-state 的 #:layout-config）。layout 骨架不认识本文件。
;;;
;;; 换一套规则（例如 IDE 风格全是可拆 panel）时，复制本文件改 hash 即可。

(require "../../layout/api.rkt")

(provide default-config)

(define default-config
  (make-layout-config
   #:rules
   (hash
    'editor
    (make-panel-rule #:splittable? #t
                     #:hideable? #f
                     #:deletable? #t
                     #:focusable? #t
                     #:min-w 1 #:max-w #f
                     #:min-h 1 #:max-h #f)
    'sidebar
    (make-panel-rule #:splittable? #f
                     #:hideable? #t
                     #:deletable? #t
                     #:focusable? #t
                     #:min-w 1 #:max-w #f
                     #:min-h 1 #:max-h #f)
    'status
    (make-panel-rule #:splittable? #f
                     #:hideable? #f
                     #:deletable? #f
                     #:focusable? #t
                     #:min-w 1 #:max-w #f
                     #:min-h 1 #:max-h #f))))
