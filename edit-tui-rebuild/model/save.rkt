#lang racket

;;; model/save.rkt —— 保存确认流程（框架级，纯数据）
;;;
;;; 退出 / 关闭文档时如果还有 dirty 文档，就排一个队列逐个问：
;;;
;;;   docs   : (listof doc-id)        待确认的文档（顺序 = 询问顺序）
;;;   index  : natural               当前问第几个
;;;   action : 'quit | (cons 'close-doc doc-id)
;;;            全部处理完后要做的事（由 bootstrap/commands.rkt 解释）
;;;
;;; 它属于框架而不是某个面板：quit / close-doc 是框架命令，
;;; 资源列表面板只是“能看到 dirty 状态”的观察者（拔掉面板也必须能保存退出）。
;;; 所以放在 state.confirm，而不是插件的 store 槽里。

(provide (struct-out save-confirm)
         make-save-confirm)

(struct save-confirm (docs index action) #:transparent)

(define (make-save-confirm docs action [index 0])
  (unless (list? docs) (error 'make-save-confirm "docs 要是 list：~a" docs))
  (unless (exact-nonnegative-integer? index)
    (error 'make-save-confirm "index 要是非负整数：~a" index))
  (save-confirm docs index action))
