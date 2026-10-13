#lang racket

;;; slots.rkt —— 开放槽：注册表 + 分配 + fork 计划
;;;
;;; 槽 = 特性在设计时声明的、随版本变化的 **opaque** 存储（core 不懂语义）。
;;; 固定语义的端口（face / readonly）不是槽，见 text/document.rkt。
;;;
;;; 槽的声明顺序即 index；document 只持一个 slots 结构，不认识槽名。
;;; 上层用 **slot 句柄**（名字 + index）寻址，避免裸 index 传错。
;;;
;;; 策略（声明时给）：
;;;     reset       新版本取 default（空 = 待算；异步结果缓存用）
;;;     transform   新版本 = (transform 旧值 ctx)，按 fork-ctx 计算
;;;
;;; 不变量：
;;;   · 每版本新建 box，旧版本的 box 永不被污染；
;;;   · 注册必须早于任何 document 创建（首个 document-open 时冻结）。

(provide
 register-slot! slot-count
 slots-frozen? freeze-slots!
 (struct-out slots)
 (struct-out slot)
 make-slots
 slot-ref slot-set! slot-atom
 fork-slots (struct-out fork-ctx))

(struct slot-spec (name default policy transform) #:transparent)
;; name      : symbol
;; default   : any/c
;; policy    : 'reset | 'transform
;; transform : (any/c fork-ctx -> any/c)   仅 'transform 用

;; 槽句柄：名字 + index。上层拿它寻址（而不是裸整数）。
(struct slot (name index) #:transparent)

;; fork 上下文：一次文档 fork 传给各 transform 槽的输入。
(struct fork-ctx (edit changes old-text new-text) #:transparent)
;; edit     : (track -> track)   把这次编辑作用到一条轨上（轨型槽用）
;; changes  : (listof change)    本次 fork 的变更描述（自定义槽用）
;; old-text : track              编辑前文本轨
;; new-text : track              编辑后文本轨

;; 槽容器：一个 box 向量（每槽一格），封装成结构体与端口区分。
(struct slots (cells) #:transparent)

(define registry (box '()))          ; (listof slot-spec)，index = 位置
(define frozen? (box #f))

;; 槽访问器统一生成 `document-slot-<name>`；这些名字会与核心名撞，禁止用作槽名。
(define reserved-names '(ref atom))

(define (slot-count) (length (unbox registry)))
(define (slots-frozen?) (unbox frozen?))
(define (freeze-slots!) (set-box! frozen? #t))

(define (register-slot! name default policy [transform #f])
  (when (unbox frozen?)
    (error 'register-slot! "槽注册必须早于任何 document 创建：~a" name))
  (when (memq name reserved-names)
    (error 'register-slot! "~a 会与核心槽访问器撞名，不能作为槽名" name))
  (define i (slot-count))
  (set-box! registry
            (append (unbox registry) (list (slot-spec name default policy transform))))
  (slot name i))

;; 新建槽容器：按注册表建默认 box。
(define (make-slots)
  (slots (list->vector (for/list ([s (in-list (unbox registry))]) (box (slot-spec-default s))))))

;; 通用访问（收 slot 句柄；cells 长度 == 注册表长度，无短向量）。
(define (slot-ref sl h) (unbox (vector-ref (slots-cells sl) (slot-index h))))
(define (slot-set! sl h v) (set-box! (vector-ref (slots-cells sl) (slot-index h)) v))
(define (slot-atom sl h) (vector-ref (slots-cells sl) (slot-index h)))

;; fork：每槽按策略产生新值。
(define (fork-slots sl ctx)
  (define cells (slots-cells sl))
  (define n (vector-length cells))
  (slots
   (list->vector
    (for/list ([s (in-list (unbox registry))] [i (in-naturals)])
      (define old (if (< i n) (unbox (vector-ref cells i)) (slot-spec-default s)))
      (box (case (slot-spec-policy s)
             [(reset) (slot-spec-default s)]
             [(transform) ((slot-spec-transform s) old ctx)]
             [else (slot-spec-default s)]))))))
