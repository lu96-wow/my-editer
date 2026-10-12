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
         world-set-layout world-set-floats world-set-focus world-set-prefix
         world-set-drag world-set-content
         focused? has-id?)

(require racket/list "../layout/tree.rkt" "drag.rkt")

(struct world (layout floats focus prefix drag content) #:transparent)
;; layout  : 布局树（不透明 id）
;; floats  : (listof float)
;; focus   : id | #f
;; prefix  : symbol | #f
;; drag    : idle | dragging
;; content : 内容层的不透明值（core 不解释）

(define (make-world #:layout [layout #f] #:floats [floats '()]
                    #:focus [focus #f] #:prefix [prefix #f] #:drag [drag (idle)]
                    #:content [content #f])
  (world layout floats focus prefix drag content))

(define (world-set-layout w l) (struct-copy world w [layout l]))
(define (world-set-floats w f) (struct-copy world w [floats f]))
(define (world-set-focus w f) (struct-copy world w [focus f]))
(define (world-set-prefix w p) (struct-copy world w [prefix p]))
(define (world-set-drag w d) (struct-copy world w [drag d]))
(define (world-set-content w c) (struct-copy world w [content c]))

(define (focused? w) (and (world-focus w) #t))
(define (has-id? w id) (and (memv id (ids (world-layout w))) #t))
