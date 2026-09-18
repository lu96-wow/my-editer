#lang racket

;;; key.rkt —— core 解释的属性键（「控制键」）词表
;;;
;;; 属性与 overlay 的 plist 是开放的「键 → 值」袋，里面混着两类键：
;;;
;;;   表现层键   给后端看（'face 等），逐字进入 screen 的 run.face
;;;   控制键     给 core 机制看（编辑守卫 / 层叠顺序 / 生命周期），不表现
;;;
;;; 控制键由 core 解释，所以：
;;;   · 投影时被滤掉，绝不进入 screen 的 face（render.rkt）
;;;   · 在插入边界不继承——它是区域语义的起点，不是一段可延续的样式（properties.rkt）
;;;
;;; 键名字面量只在这里出现一次；机制与投影都从这里取词表，
;;; 避免同一个魔法键名散落在多个模块、各自维护。
;;;
;;; 各键的语义归属：
;;;   read-only  编辑守卫（buffer.rkt）：区间不可编辑
;;;   priority   层叠顺序（render.rkt 的 compute-face）：≤0 在属性之下，>0 之上
;;;   evaporate  overlay 生命周期（overlay.rkt）：覆盖的文本被删光即消亡

(provide control-keys
         control-key?)

(define control-keys '(read-only priority evaporate))

;; 是否是控制键。统一成 #t/#f（memq 的返回值是子表或 #f）。
(define (control-key? k)
  (and (memq k control-keys) #t))

(module+ test
  (require rackunit)

  (check-equal? control-keys '(read-only priority evaporate))
  (check-true  (control-key? 'read-only))
  (check-true  (control-key? 'priority))
  (check-true  (control-key? 'evaporate))
  (check-false (control-key? 'face))
  (check-false (control-key? 'foreground))

  (displayln "key.rkt: all tests passed"))