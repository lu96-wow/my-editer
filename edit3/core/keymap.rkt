#lang racket

;;; edit3/keymap.rkt —— 键表（**纯**）：条目列表 + 顺序组合（由 edit2 平移）
;;;
;;; 表 = (listof entry)；entry = (binding scope op ...)，见 config/keys.rkt。
;;;
;;; 「组合」和「绑定到 document」是两个**独立**功能：
;;;   · 组合（本模块）：把多张表按顺序并起来，后表在 (binding scope) 相同时覆盖前表；
;;;   · 绑定（core/step.rkt）：把某张表挂到某个 did 上，焦点在该文档时优先用它。
;;; 本模块不认识 State / 路由，只对纯数据做代数。

(provide compose-keymaps keymap-add
         entry-binding entry-scope same-slot?)

(define (entry-binding e) (car e))
(define (entry-scope e) (cadr e))

;; 是否同一「格子」：绑定键 + 作用域都一样才算重合。
(define (same-slot? a b)
  (and (equal? (entry-binding a) (entry-binding b))
       (equal? (entry-scope a) (entry-scope b))))

;; tables : (listof (listof entry))，先 → 后；后者覆盖前者（且替换其位置）。
(define (compose-keymaps tables)
  (for/fold ([acc '()]) ([t (in-list tables)])
    (for/fold ([acc acc]) ([e (in-list t)])
      (append (filter-not (lambda (x) (same-slot? e x)) acc) (list e)))))

;; 单条加/覆盖（为便于在已有表上补一条）。
(define (keymap-add table e)
  (append (filter-not (lambda (x) (same-slot? e x)) table) (list e)))
