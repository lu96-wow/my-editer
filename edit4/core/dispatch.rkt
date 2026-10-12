#lang racket

;;; edit4/core/dispatch.rkt —— 输入求值
;;;
;;; 顺序试 keymap：第一个「binding 命中 + scope 成立 + 不 decline」的 entry 生效。
;;; prefix 与已按键序列（keys）是 World 的普通字段：进入前缀时累积，跑完 / 未命中即清。
;;; scope 注册表在 core/scope.rkt；命令按名查注册表（core/command.rkt）。

(provide dispatch)

(require "world.rkt" "command.rkt" "keymap.rkt" "scope.rkt" racket/list)

(define (enters-prefix? cmds)
  (for/or ([c (in-list cmds)]) (eq? 'prefix (command-name c))))

;; 清前缀与「正在输入的命令序列」。
(define (clear-input w)
  (define w1 (if (world-prefix w) (world-set-prefix w #f) w))
  (if (null? (world-keys w1)) w1 (world-set-keys w1 '())))

;; dispatch : registry scopes keymap ctx world -> (values world (listof effect))
(define (dispatch reg scopes keymap ctx world)
  (define ev (ctx-event ctx))
  (define (try es)
    (cond
      [(null? es) (values (clear-input world) '())]      ; 未命中 → 清前缀/键序列
      [else
       (define e (car es))
       (cond
         [(and ((parse-binding (entry-binding e)) ev)
               (scope-ok? scopes world (entry-scope e)))
          (define cmds (entry-commands e))
          (define label (binding-label (entry-binding e)))
          (define r (run-commands reg ctx world cmds))
          (cond
            [(not r) (try (cdr es))]                       ; decline → 下一条
            [else
             (define w* (car r))
             (cond
               [(enters-prefix? cmds)                      ; 进入前缀：累积键序列
                (values (world-set-keys w* (if label (append (world-keys w*) (list label))
                                               (world-keys w*)))
                        (cdr r))]
               [else (values (clear-input w*) (cdr r))])])]
         [else (try (cdr es))])]))
  (try keymap))
