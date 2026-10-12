#lang racket

;;; edit4/core/world.rkt —— 命令层作用的唯一状态
;;;
;;; World 是值：布局树 + 浮窗表 + 焦点 + prefix（模式）+ drag（手势）。
;;; 「id ↔ 窗口/视图/文档」的绑定不在这里；命令层只操作不透明 id。

(provide (struct-out world) make-world
         world-set-layout world-set-floats world-set-focus world-set-prefix world-set-drag world-set-content
         feature-ref feature-set
         focused? has-id?)

(require "../layout.rkt" "drag.rkt")

;; content 是不透明字段（内容层自己解释），core 不依赖内容层。
;; features 是命名空间化的局部状态（面板/插件用），键约定 (namespace . key)。
(struct world (layout floats focus prefix drag content features) #:transparent)

(define (make-world #:layout [layout #f] #:floats [floats '()]
                    #:focus [focus #f] #:prefix [prefix #f] #:drag [drag (idle)]
                    #:content [content #f] #:features [features (hash)])
  (world layout floats focus prefix drag content features))

(define (world-set-layout w l) (struct-copy world w [layout l]))
(define (world-set-floats w f) (struct-copy world w [floats f]))
(define (world-set-focus w f) (struct-copy world w [focus f]))
(define (world-set-prefix w p) (struct-copy world w [prefix p]))
(define (world-set-drag w d) (struct-copy world w [drag d]))
(define (world-set-content w c) (struct-copy world w [content c]))

(define (feature-ref w k d) (hash-ref (world-features w) k d))
(define (feature-set w k v) (struct-copy world w [features (hash-set (world-features w) k v)]))

(define (focused? w) (and (world-focus w) #t))
(define (has-id? w id) (and (memv id (ids (world-layout w))) #t))
