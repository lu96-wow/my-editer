#lang racket

;;; model/resources.rkt —— 全局资源管理状态（纯数据）
;;;
;;; 当前只有 save-confirm 流程：
;;;   docs   : 待处理的 dirty doc-id（按打开顺序 / 扫描顺序）
;;;   index  : 当前处理到第几个
;;;   action : 全部处理完之后要执行的动作
;;;            'quit | (cons 'close-doc doc-id)
;;;
;;; y/n/yall/nall 的选择只改 index / 跳过剩余；真正 save/close/quit
;;; 仍由命令发 effect。

(provide (struct-out save-confirm)
         (struct-out resources)
         make-save-confirm
         make-resource-state
         resources-empty
         resources-set-confirm
         resources-confirm)

(struct save-confirm (docs index action) #:transparent)

(define (make-save-confirm docs action [index 0])
  (save-confirm docs index action))

(struct resources (confirm) #:transparent)

(define (resources-empty) (resources #f))

(define (make-resource-state #:confirm [confirm #f])
  (resources confirm))

(define (resources-set-confirm r c) (struct-copy resources r [confirm c]))
