#lang racket

;;; edit4/core/keymap.rkt —— 绑定 / 键表（纯数据）
;;;
;;; binding 数据：
;;;   (key k mod…)         按键（mods 顺序无关）
;;;   (text)               任意文本
;;;   (text "x")           指定文本
;;;   (cursor kind)        任意鼠标该 kind（press|release|move|scroll）
;;;   (cursor kind button) 指定按键
;;;
;;; entry = (binding scope command…)。组合：同 (binding scope) 的后者覆盖前者。

(provide parse-binding binding-label
         entry-binding entry-scope entry-commands same-slot?
         compose-keymaps)

(require "event.rkt" racket/list)

;;; ---------- binding → 事件谓词 ----------

(define (mods=? a b) (equal? (sort a symbol<?) (sort b symbol<?)))

(define (parse-binding b)
  (cond
    [(and (pair? b) (eq? 'key (car b)))
     (lambda (ev) (and (key-event? ev)
                       (eq? (cadr b) (key-event-key ev))
                       (mods=? (cddr b) (key-event-mods ev))))]
    [(and (pair? b) (eq? 'text (car b)))
     (if (pair? (cdr b))
         (lambda (ev) (and (text-event? ev) (equal? (cadr b) (text-event-text ev))))
         (lambda (ev) (text-event? ev)))]
    [(and (pair? b) (eq? 'cursor (car b)))
     (define k (cadr b))
     (define btn (and (pair? (cddr b)) (caddr b)))
     (lambda (ev) (and (cursor-event? ev)
                       (eq? k (cursor-event-kind ev))
                       (or (not btn) (eq? btn (cursor-event-button ev)))))]
    [else (error 'parse-binding "坏 binding: ~a" b)]))

(define (key-name k)
  (case k
    [(up) "↑"] [(down) "↓"] [(left) "←"] [(right) "→"]
    [(enter) "Enter"] [(escape) "Esc"] [(tab) "Tab"] [(space) "Space"]
    [(backspace) "BS"] [(delete) "Del"]
    [else (symbol->string k)]))

;; 回显用标签（#f = 不值得回显）
(define (binding-label b)
  (case (car b)
    [(key) (string-append (if (memq 'ctrl (cddr b)) "C-" "")
                          (if (memq 'alt (cddr b)) "M-" "")
                          (if (memq 'shift (cddr b)) "S-" "")
                          (key-name (cadr b)))]
    [(cursor) (format "Mouse:~a" (cadr b))]
    [(text) (and (pair? (cdr b)) (cadr b))]
    [else #f]))

;;; ---------- entry ----------

(define (entry-binding e) (car e))
(define (entry-scope e) (cadr e))
(define (entry-commands e) (cddr e))

(define (same-slot? a b)
  (and (equal? (entry-binding a) (entry-binding b))
       (equal? (entry-scope a) (entry-scope b))))

;; tables : (listof (listof entry))；后者覆盖前者（同 slot 的替换）。
(define (compose-keymaps tables)
  (for/fold ([acc '()]) ([t (in-list tables)])
    (for/fold ([acc acc]) ([e (in-list t)])
      (append (filter-not (lambda (x) (same-slot? e x)) acc) (list e)))))
