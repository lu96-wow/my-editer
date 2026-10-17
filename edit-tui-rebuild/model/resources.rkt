#lang racket

;;; model/resources.rkt —— 资源列表面板的**自己的**状态（插件切片，纯数据）
;;;
;;;   collapsed : doc-id -> #t        资源列表里折叠的 document
;;;   view      : #f | view-id        资源列表面板自己的 view
;;;
;;; 这个切片放在 state.store 的 'resources 槽里（见 bootstrap/resource-panel.rkt），
;;; 不是根 State 的字段：拔掉资源面板插件后，这部分状态跟着消失，框架不受影响。
;;;
;;; 不在这里的两个近邻：
;;;   · 保存确认队列  -> model/save.rkt（框架级：quit / close-doc 要用）
;;;   · placement     -> workspace.placement（框架级：文件树面板也会发起）
;;;
;;; 面板没安装时是 (resource-panel-empty)：投影 / 同步都是 no-op。

(provide (struct-out resource-panel)
         resource-panel-empty
         resource-panel-collapsed?
         resource-panel-toggle-collapse
         resource-panel-view
         resource-panel-set-view)

(struct resource-panel (collapsed view) #:transparent)
;; collapsed : (hash/c doc-id #t)
;; view      : view-id | #f

(define (resource-panel-empty) (resource-panel (hash) #f))

(define (resource-panel-collapsed? r did)
  (hash-has-key? (resource-panel-collapsed r) did))

(define (resource-panel-toggle-collapse r did)
  (define h (resource-panel-collapsed r))
  (struct-copy resource-panel r
               [collapsed (if (hash-has-key? h did)
                              (hash-remove h did)
                              (hash-set h did #t))]))

(define (resource-panel-set-view r vid)
  (struct-copy resource-panel r [view vid]))
