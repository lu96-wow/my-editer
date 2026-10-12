#lang racket

;;; edit4/core/command.rkt —— 命令数据 + 注册表 + 求值
;;;
;;; Command 是命名意图（配置数据）：(command name args)。
;;; handler 只依赖 Ctx + World + args，**不认识事件本身**（需要事件数据时从 Ctx 取）。
;;; 返回 #f 表示「让位」（decline），由 dispatch 尝试下一条绑定。
;;;
;;; 名字是**配置接口**：键表用数据写、插件可按名覆盖。运行时按名查一次注册表即可
;;; —— 这已经是「数据 + 函数」的组合（见 run-commands），不需要再抽一层解析阶段。

(provide (struct-out ctx) (struct-out command) cmd
         (struct-out command-registry)
         make-command-registry command-register command-lookup command-names
         command-registry-merge
         run-command run-commands)

(struct ctx (event size frame) #:transparent)
;; event : 本次输入事件
;; size  : (cons w h)
;; frame : 布局 frame（平铺几何 + 浮窗矩形；可能 #f，未算）

(struct command (name args) #:transparent)

(define (cmd name . args) (command name args))

(struct command-registry (table) #:transparent)     ; name -> handler
;; handler : ctx world args -> (values world effects) | #f

;; entries : (listof (cons name handler))
(define (make-command-registry [entries '()])
  (command-registry (for/hash ([e (in-list entries)]) (values (car e) (cdr e)))))

(define (command-register reg name handler)
  (command-registry (hash-set (command-registry-table reg) name handler)))

(define (command-lookup reg name)
  (hash-ref (command-registry-table reg) name #f))

(define (command-names reg) (hash-keys (command-registry-table reg)))

;; 叠加：b 覆盖 a 的同名命令。
(define (command-registry-merge a b)
  (command-registry
   (for/fold ([t (command-registry-table a)]) ([(k v) (in-hash (command-registry-table b))])
     (hash-set t k v))))

;; run-command : registry ctx world command -> (values world effects) | #f
;;   未知命令或命令让位 → #f。
(define (run-command reg ctx world c)
  (define h (command-lookup reg (command-name c)))
  (if h (h ctx world (command-args c)) #f))

;; run-commands : registry ctx world (listof command) -> (cons world effects) | #f
;;   任一条让位 → 整体让位（World 是值，直接丢掉即可）。
(define (run-commands reg ctx world cmds)
  (let loop ([w world] [effs '()] [cs cmds])
    (cond
      [(null? cs) (cons w effs)]
      [else
       (define r (run-command reg ctx w (car cs)))
       (cond
         [(not r) #f]
         [else (loop (car r) (append effs (cdr r)) (cdr cs))])])))
