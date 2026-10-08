#lang racket

;;; slot-dsl.rkt —— 文档槽声明 DSL
;;;
;;; 上层在"设计时"声明自己需要的槽，宏生成：
;;;   · 名字本身绑定到 **slot 句柄**（注册到 slots.rkt，扩展 fork 计划）—— 通用 API 的句柄
;;;   · 命名读访问器   document-slot-<name>
;;;   · 命名写访问器   document-set-slot-<name>!
;;;   · 裸 atom 访问器 document-slot-<name>-atom（异步写回用）
;;;
;;; 访问器统一带 `slot-` 前缀，从构造上避免与端口 / 核心 `document-*` 名冲突。
;;; document 本身不认识这些槽。
;;;
;;;     (define-document-slot meta-a #:default #f #:fork reset)
;;;     (define-document-slot tlen   #:default 0  #:fork (transform my-fn))
;;;
;;; 名字即句柄：可传给 editor-document-slot-* / editor-document-slot-ref 等通用 API。
;;; 注册必须早于任何 document 创建（见 slots.rkt 的冻结）。

(require "document.rkt" "slots.rkt"
         (for-syntax racket/syntax))

(provide define-document-slot)

(define-syntax (define-document-slot stx)
  (syntax-case stx (reset transform)
    [(_ name #:default default #:fork reset)
     (with-syntax ([ref-id  (format-id stx "document-slot-~a" #'name)]
                   [set-id  (format-id stx "document-set-slot-~a!" #'name)]
                   [atom-id (format-id stx "document-slot-~a-atom" #'name)])
       #'(begin
           (define name (register-slot! 'name default 'reset))
           (define (ref-id bd) (slot-ref (document-slots bd) name))
           (define (set-id bd v) (slot-set! (document-slots bd) name v))
           (define (atom-id bd) (slot-atom (document-slots bd) name))))]
    [(_ name #:default default #:fork (transform fn))
     (with-syntax ([ref-id  (format-id stx "document-slot-~a" #'name)]
                   [set-id  (format-id stx "document-set-slot-~a!" #'name)]
                   [atom-id (format-id stx "document-slot-~a-atom" #'name)])
       #'(begin
           (define name (register-slot! 'name default 'transform fn))
           (define (ref-id bd) (slot-ref (document-slots bd) name))
           (define (set-id bd v) (slot-set! (document-slots bd) name v))
           (define (atom-id bd) (slot-atom (document-slots bd) name))))]))
