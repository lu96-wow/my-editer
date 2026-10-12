#lang racket

;;; edit4/core/world.rkt —— 命令层作用的唯一状态（值）
;;;
;;; World 只装「可变的领域状态」：布局 / 浮窗 / 焦点 / prefix / 手势 / 内容。
;;; 注册表、路由、钩子、服务是「装配期只读」，属于 Environment（env.rkt），不进 World。
;;;
;;; 两条不变量：
;;;   · 没有 hash 状的「杂物袋」——每个字段都有类型、有来源（edit3 的 features hash 已移除）；
;;;   · content 是不透明字段，由内容层解释，core 不 require 内容层。

(provide (struct-out world) make-world
         world-set-layout world-set-floats world-set-focus world-set-prefix world-set-keys
         world-set-drag world-set-content world-set-signals world-set-jobs world-set-store
         emit!
         focused? has-id?)

(require racket/list "../layout/tree.rkt" "drag.rkt" "store.rkt")

(struct world (layout floats focus prefix keys drag content signals jobs store) #:transparent)
;; layout  : 布局树（不透明 id）
;; floats  : (listof float)
;; focus   : id | #f
;; prefix  : symbol | #f
;; keys    : (listof string)   当前多键命令已按的键（供状态栏显示）
;; drag    : idle | dragging
;; content : 内容层的不透明值（core 不解释）
;; signals : (listof (cons point args))  待跑的钩子信号（core/hook.rkt 排空）
;; jobs    : 不透明 job 账本（core/job.rkt 解释；#f = 空）
;; store   : 插件局部状态（core/store.rkt，命名空间隔离）

(define (make-world #:layout [layout #f] #:floats [floats '()]
                    #:focus [focus #f] #:prefix [prefix #f] #:keys [keys '()]
                    #:drag [drag (idle)] #:content [content #f]
                    #:signals [signals '()] #:jobs [jobs #f] #:store [store (make-store)])
  (world layout floats focus prefix keys drag content signals jobs store))

(define (world-set-layout w l) (struct-copy world w [layout l]))
(define (world-set-floats w f) (struct-copy world w [floats f]))
(define (world-set-focus w f) (struct-copy world w [focus f]))
(define (world-set-prefix w p) (struct-copy world w [prefix p]))
(define (world-set-keys w k) (struct-copy world w [keys k]))
(define (world-set-drag w d) (struct-copy world w [drag d]))
(define (world-set-content w c) (struct-copy world w [content c]))
(define (world-set-signals w s) (struct-copy world w [signals s]))
(define (world-set-jobs w j) (struct-copy world w [jobs j]))
(define (world-set-store w s) (struct-copy world w [store s]))

;; 命令发钩子：追加一条信号（core，不需要 Environment）。
(define (emit! w point args) (world-set-signals w (append (world-signals w) (list (cons point args)))))

(define (focused? w) (and (world-focus w) #t))
(define (has-id? w id) (and (memv id (ids (world-layout w))) #t))
