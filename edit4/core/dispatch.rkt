#lang racket

;;; edit4/core/dispatch.rkt —— 输入求值
;;;
;;; 顺序试 keymap：第一个「binding 命中 + scope 成立 + 不 decline」的 entry 生效。
;;; prefix 与已按键序列（keys）是 World 的普通字段：进入前缀时累积，跑完 / 未命中即清。
;;; scope 注册表在 core/scope.rkt；命令按名查注册表（core/command.rkt）。

(provide dispatch)

(require "world.rkt" "command.rkt" "keymap.rkt" "scope.rkt" racket/list)

;; 会进入 / 停留多键前缀的命令：`prefix`（分屏）与 `prefix-new`（新建）。
(define (enters-prefix? cmds)
  (for/or ([c (in-list cmds)]) (memq (command-name c) '(prefix prefix-new))))

;; 清前缀与「正在输入的命令序列」。
(define (clear-input w)
  (define w1 (if (world-prefix w) (world-set-prefix w #f) w))
  (if (null? (world-keys w1)) w1 (world-set-keys w1 '())))

;; 前缀激活时，该前缀的绑定先试（prefix 是模态的）——否则会被 editor/panel 绑定抢走。
(define (prefix-first table w)
  (define p (world-prefix w))
  (cond
    [(not p) table]
    [else (define-values (hi lo)
            (partition (lambda (e) (equal? (entry-scope e) (list 'prefix p))) table))
          (append hi lo)]))

;; dispatch : registry scopes keymap ctx world [#:doc-keymap 文档键表] -> (values world (listof effect))
;;   文档键表（若有）先试，未命中 / 让位再落全局 keymap。
(define (dispatch reg scopes keymap ctx world #:doc-keymap [doc-keymap '()])
  (define ev (ctx-event ctx))
  (define table (if (null? doc-keymap) keymap (append doc-keymap keymap)))
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
               [(and (world-prefix w*) (enters-prefix? cmds))   ; 进入 / 停留前缀：累积键序列
                (values (world-set-keys w* (if label (append (world-keys w*) (list label))
                                               (world-keys w*)))
                        (cdr r))]
               [else (values (clear-input w*) (cdr r))])])]
         [else (try (cdr es))])]))
  (try (prefix-first table world)))
