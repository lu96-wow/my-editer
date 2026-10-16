#lang racket

;;; command/command.rkt —— 表叶子上的「命令」：要跑的过程 + 说明 + 输入需求
;;;
;;; 表（keymap）只认 token → 叶子。叶子以前是裸过程，现在统一是一份 command：
;;;
;;;     run   : 过程                          真正执行
;;;     note  : #f | string | (-> string)      说明（which-key / 状态栏 / 帮助）
;;;     input : #f | input                     触发后要先接受的输入（minibuffer 之类）
;;;
;;; 说明和输入需求都**随表存**：state 层不必再维护一张「序列 → 元信息」表，
;;; 直接拿查表结果里的 command 即可。这样 which-key / 提示 / 输入都由同一份数据驱动。
;;;
;;; 构造：
;;;     (cmd #:note "保存"        (λ () (save)))
;;;     (cmd #:note "另存为文件名" #:input (input 'string "文件: ") (λ (path) (save-as path)))
;;;
;;; 裸过程仍然可用（note / input 为空）：
;;;     (keys [(key 'left) (λ () (move-left))])
;;;
;;; 表只管存，不管「怎么问用户」。触发后 state 层看 (command-input c)：
;;;   #f        → ((command-run c))              直接执行
;;;   非空 spec → 先收输入 v，再 ((command-run c) v)

(provide (struct-out command)
         (struct-out input)
         cmd
         ->command
         command-note-string
         command-needs-input?
         input-kinds)

;; run   : procedure
;; note  : #f | string | (-> (or/c string #f))
;; input : #f | input?
(struct command (run note input) #:transparent)

;; kind   : 'string | 'key | 'key-seq | 'number | 'choice | 'any
;; prompt : string         提示语（放 minibuffer / 状态栏）
;; init   : any/c          初值；'choice 时是候选值表
(struct input (kind prompt init) #:transparent)

(define input-kinds '(string key key-seq number choice any))

;; 构造糖（关键字可选）。run 放最后，便于写 (cmd #:note "…" (λ …))。
(define (cmd run #:note [note #f] #:input [input #f])
  (unless (procedure? run)
    (error 'cmd "run 要是一个过程，得到 ~a" run))
  (when (and input (not (input? input)))
    (error 'cmd "input 要是 input 结构或 #f，得到 ~a" input))
  (command run note input))

;; 归一：裸过程 → command；已经是 command 就原样。keys DSL 用它。
(define (->command x)
  (cond [(command? x) x]
        [(procedure? x) (command x #f #f)]
        [else (error '->command "叶子要是过程或 command，得到 ~a" x)]))

;; 解析说明（note 允许 thunk，做状态相关文案）。
(define (command-note-string c)
  (define n (command-note c))
  (cond [(procedure? n) (n)]
        [else n]))

;; 触发后要不要先收输入。
(define (command-needs-input? c)
  (and (command-input c) #t))
