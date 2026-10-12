#lang racket

;;; edit4/core/command.rkt —— 命令：配置接口（名字）+ 解析成函数
;;;
;;; 名字只属于**配置层**：键表用 (command name args) 这种数据写，插件可覆盖同名命令。
;;; 但运行时不再「按名字查表」。装配期把每条命令解析成一个 handler 闭包：
;;;     handler : ctx world -> (values world effects) | #f
;;; 于是一次按键 = 一串 handler 的函数组合（run-handlers），没有标签在流水线里流转。
;;;
;;; （edit3 在执行器里按 tag 查 op，并让 handler 拿 ev；edit4 把「名字」和「组合」分开。）

(provide (struct-out ctx) (struct-out command) cmd
         (struct-out command-registry)
         make-command-registry command-register command-lookup command-names
         command-registry-merge
         resolve-command resolve-commands run-handlers)

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

;;; ---------- 解析（名字 → 函数；只在装配期跑一次） ----------

;; resolve-command : registry command -> (ctx world -> (values world effects) | #f) | #f
;;   未知命令 → #f（整条 binding 解析失败，直接丢弃）。
(define (resolve-command reg c)
  (define h (command-lookup reg (command-name c)))
  (and h (lambda (ctx world) (h ctx world (command-args c)))))

;; resolve-commands : registry (listof command) -> (listof handler) | #f
(define (resolve-commands reg cmds)
  (cond
    [(null? cmds) '()]
    [else
     (define h (resolve-command reg (car cmds)))
     (and h (cons h (resolve-commands reg (cdr cmds))))]))

;; 函数组合：一串 handler 顺序跑，任一条让位（#f）→ 整体让位。
(define (run-handlers ctx world hs)
  (let loop ([w world] [effs '()] [hs hs])
    (cond
      [(null? hs) (cons w effs)]
      [else
       (define r ((car hs) ctx w))
       (cond
         [(not r) #f]
         [else (loop (car r) (append effs (cdr r)) (cdr hs))])])))
