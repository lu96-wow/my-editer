#lang racket

;;; edit4/core/drag.rkt —— 手势状态（数据）
;;;
;;; 拖拽 = 按下时的快照；move 只依赖「快照 + 总位移」，所以幂等、不漂。
;;; target :
;;;   (list 'cut xsegs ysegs)                    平铺缝：两条线上全部缝段快照
;;;   (list 'float id action float0 rel0)        浮窗：原始 float + move/resize角 + 参照矩形

(provide (struct-out idle) (struct-out dragging))

(struct idle () #:transparent)
(struct dragging (start-x start-y target) #:transparent)
