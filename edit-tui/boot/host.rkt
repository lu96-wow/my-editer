#lang racket

;;; edit-tui-rebuild/boot/host.rkt —— 启动上下文
;;;
;;; host 只在 boot 阶段使用：
;;;   engine           core buffer/view 持有者
;;;   layout-config    具体布局规则
;;;   keymap           具体键位
;;;   plugins          插件值列表（顺序 = 安装顺序）
;;;   id allocator     UI view / panel id
;;;
;;; id 分配是 boot 阶段少数允许的可变状态；插件安装完就只读。

(require "../core/skeleton.rkt"
         "../app/keymap.rkt")

(provide (struct-out host)
         make-host
         host-alloc-view-id!
         host-alloc-panel-id!)

(struct host
  (engine
   layout-config
   keymap
   plugins
   view-counter
   panel-counter)
  #:transparent)

(define (make-host
         #:engine engine
         #:layout-config [layout-config empty-layout-config]
         #:keymap [keymap empty-keymap]
         #:plugins [plugins '()]
         #:first-view-id [first-view-id 10]
         #:first-panel-id [first-panel-id 100])
  (host engine
        layout-config
        keymap
        plugins
        (box first-view-id)
        (box first-panel-id)))

(define (host-alloc-view-id! host)
  (define b (host-view-counter host))
  (begin0 (unbox b) (set-box! b (add1 (unbox b)))))

(define (host-alloc-panel-id! host)
  (define b (host-panel-counter host))
  (begin0 (unbox b) (set-box! b (add1 (unbox b)))))
