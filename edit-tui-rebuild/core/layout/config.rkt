#lang racket

;;; edit-tui-rebuild/layout/config.rkt —— 布局配置模型（骨架）
;;;
;;; 这里只定义“规则的数据形状”和通用行为：
;;;   panel-rule / layout-config 类型
;;;   make-* / 查询 / 通用 default-panel-rule
;;;
;;; 具体 panel kind（editor / sidebar / status …）的规则属于 configuration，
;;; 放在 config/layout/；本文件不 require 它，也不知道任何 kind。
;;;
;;; min / max 不进入布局状态；启动校验与运行时 API 从这里取限制。
;;; 未知 kind 用 default-rule。

(provide (struct-out panel-rule)
         (struct-out layout-config)
         make-panel-rule
         make-layout-config
         default-panel-rule
         empty-layout-config
         config-panel-rule
         config-panel-splittable?
         config-panel-hideable?
         config-panel-deletable?
         config-panel-focusable?
         panel-rule-min-size
         panel-rule-max-size)

(struct panel-rule
  (splittable? hideable? deletable? focusable?
   min-w max-w min-h max-h)
  #:transparent)

(struct layout-config (rules default-rule) #:transparent)
;; rules        : (hash/c symbol panel-rule)
;; default-rule : panel-rule

(define (check-limit who min max)
  (unless (and (exact? min) (integer? min) (>= min 0))
    (error who "min 要非负整数：~a" min))
  (unless (or (not max) (and (exact? max) (integer? max) (>= max min)))
    (error who "max 要 #f 或 >= min 的整数：~a" max)))

(define (make-panel-rule
         #:splittable? [splittable? #f]
         #:hideable? [hideable? #f]
         #:deletable? [deletable? #t]
         #:focusable? [focusable? #t]
         #:min-w [min-w 0]
         #:max-w [max-w #f]
         #:min-h [min-h 0]
         #:max-h [max-h #f])
  (check-limit 'make-panel-rule min-w max-w)
  (check-limit 'make-panel-rule min-h max-h)
  (panel-rule splittable? hideable? deletable? focusable?
              min-w max-w min-h max-h))

(define default-panel-rule
  (make-panel-rule #:splittable? #f
                   #:hideable? #f
                   #:deletable? #t
                   #:focusable? #t
                   #:min-w 0 #:max-w #f
                   #:min-h 0 #:max-h #f))

(define (make-layout-config
         #:rules [rules (hash)]
         #:default [default default-panel-rule])
  (unless (hash? rules)
    (error 'make-layout-config "rules 要是 hash：~a" rules))
  (unless (panel-rule? default)
    (error 'make-layout-config "default 要是 panel-rule：~a" default))
  (layout-config rules default))

;; 没有任何 per-kind 规则：所有 kind 都落到 default-panel-rule。
;; app/state 用它当默认值；宿主选择具体布局时传入 config/layout/ 里的 config。
(define empty-layout-config
  (make-layout-config))

(define (config-panel-rule config kind)
  (or (hash-ref (layout-config-rules config) kind #f)
      (layout-config-default-rule config)))

(define (config-panel-splittable? config kind)
  (panel-rule-splittable? (config-panel-rule config kind)))

(define (config-panel-hideable? config kind)
  (panel-rule-hideable? (config-panel-rule config kind)))

(define (config-panel-deletable? config kind)
  (panel-rule-deletable? (config-panel-rule config kind)))

(define (config-panel-focusable? config kind)
  (panel-rule-focusable? (config-panel-rule config kind)))

(define (panel-rule-min-size rule axis)
  (case axis
    [(lr) (panel-rule-min-w rule)]
    [(tb) (panel-rule-min-h rule)]
    [else (error 'panel-rule-min-size "axis 要是 'lr 或 'tb：~a" axis)]))

(define (panel-rule-max-size rule axis)
  (case axis
    [(lr) (panel-rule-max-w rule)]
    [(tb) (panel-rule-max-h rule)]
    [else (error 'panel-rule-max-size "axis 要是 'lr 或 'tb：~a" axis)]))
