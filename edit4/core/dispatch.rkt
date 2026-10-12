#lang racket

;;; edit4/core/dispatch.rkt —— 输入求值（在已解析的键表上）
;;;
;;; 装配期先用 resolve-keymap 把「名字」解析成函数（见 command.rkt）；
;;; 运行时只做两件事：顺序试 binding/scope，命中就把函数组合跑掉。
;;; 流水线里没有任何 tag / registry 查表。
;;;
;;; prefix 是 World 的普通字段：跑完非 prefix binding 自动清；未命中事件也清。

(provide dispatch resolve-keymap)

(require "world.rkt" "command.rkt" "keymap.rkt" "scope.rkt" racket/list)

;; 已解析的键表项：binding/scope 仍是数据，handlers 是函数。
(struct bound (binding scope enters-prefix? handlers) #:transparent)

(define (enters-prefix? cmds)
  (for/or ([c (in-list cmds)]) (eq? 'prefix (command-name c))))

;; resolve-keymap : registry keymap -> (listof bound)
;;   未知命令的 entry 直接丢弃（等价于永远让位）。
(define (resolve-keymap reg keymap)
  (filter-map
   (lambda (e)
     (define cmds (entry-commands e))
     (define hs (resolve-commands reg cmds))
     (and hs (bound (entry-binding e) (entry-scope e) (enters-prefix? cmds) hs)))
   keymap))

(define (clear-prefix w)
  (if (world-prefix w) (world-set-prefix w #f) w))

;; dispatch : scopes (listof bound) ctx world -> (values world (listof effect))
(define (dispatch scopes keymap ctx world)
  (define ev (ctx-event ctx))
  (define (try es)
    (cond
      [(null? es) (values (clear-prefix world) '())]      ; 未命中 → 清 prefix
      [else
       (define e (car es))
       (cond
         [(and ((parse-binding (bound-binding e)) ev)
               (scope-ok? scopes world (bound-scope e)))
          (define r (run-handlers ctx world (bound-handlers e)))
          (cond
            [(not r) (try (cdr es))]                       ; decline → 下一条
            [else
             (values (if (bound-enters-prefix? e) (car r) (world-set-prefix (car r) #f))
                     (cdr r))])]
         [else (try (cdr es))])]))
  (try keymap))
