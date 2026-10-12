#lang racket

;;; edit4/core/dispatch.rkt —— 作用域注册表 + 输入求值
;;;
;;; scope 是 World 的函数，注册成数据（不再硬编码在 executor）。
;;; dispatch 顺序试 keymap：第一个「binding 命中 + scope 成立 + 不 decline」的 entry 生效。
;;; prefix 是 World 的普通字段：跑完非 prefix 命令自动清；未命中事件也清。

(provide (struct-out scope-registry)
         make-scope-registry scope-register scope-lookup scope-ok?
         dispatch)

(require "world.rkt" "command.rkt" "keymap.rkt" racket/list)

(struct scope-registry (table) #:transparent)       ; name -> (World -> Bool)

(define (make-scope-registry [entries '()])
  (scope-registry (for/hash ([e (in-list entries)]) (values (car e) (cdr e)))))

(define (scope-register reg name pred)
  (scope-registry (hash-set (scope-registry-table reg) name pred)))

(define (scope-lookup reg name)
  (hash-ref (scope-registry-table reg) name #f))

;; 内置：always； (prefix NAME)
(define (scope-ok? scopes world scope)
  (cond
    [(eq? scope 'always) #t]
    [(and (pair? scope) (eq? 'prefix (car scope)))
     (eq? (world-prefix world) (cadr scope))]
    [else (define p (scope-lookup scopes scope)) (if p (p world) #t)]))

(define (enters-prefix? cmds)
  (for/or ([c (in-list cmds)]) (eq? 'prefix (command-name c))))

(define (clear-prefix w)
  (if (world-prefix w) (world-set-prefix w #f) w))

;; dispatch : registry scopes keymap ctx world -> (values world (listof effect))
(define (dispatch reg scopes keymap ctx world)
  (define ev (ctx-event ctx))
  (define (try es)
    (cond
      [(null? es) (values (clear-prefix world) '())]      ; 未命中 → 清 prefix
      [else
       (define e (car es))
       (cond
         [(and ((parse-binding (entry-binding e)) ev)
               (scope-ok? scopes world (entry-scope e)))
          (define cmds (entry-commands e))
          (define r (run-commands reg ctx world cmds))
          (cond
            [(not r) (try (cdr es))]                       ; decline → 下一条
            [else
             (values (if (enters-prefix? cmds) (car r) (world-set-prefix (car r) #f))
                     (cdr r))])]
         [else (try (cdr es))])]))
  (try keymap))
