#lang racket

;;; lab-rebuild/kernel/dock.rkt —— 停靠区（dock）机制：通用，不认识状态行 / 文件树。
;;;
;;; dock-spec 是组装期的 contribution（kind='dock）；dock 是运行时实例。
;;; 逻辑（状态行文本 / 目录内容 / 键位）由各 builtin 自带，kernel 只提供机制。

(provide (struct-out dock-spec) (struct-out dock)
         dock-make-vid)

(struct dock-spec (id side size visible? make keys) #:transparent)
;; id      : symbol                      唯一 id
;; side    : 'left | 'right | 'top | 'bottom
;; size    : exact-nonnegative-integer   宽度（left/right）或高度（top/bottom）
;; make    : (root ed w h) -> (values ed vid)   建承载视图
;; keys    : keytable | #f               focus 在该 dock 时生效的键表

(struct dock (id side size visible? vid keys) #:transparent)

(define (dock-make-vid spec root ed w h)
  ((dock-spec-make spec) root ed w h))
