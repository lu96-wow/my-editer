#lang racket

;;; edit/core/face.rkt —— 带参 face 值 + 前景/背景分层（纯）
;;;
;;; 普通 face 是 symbol（theme 里查固定 style）。需要带参数时：
;;;   palette-color  按主题调色板 + 位置取色（如关键字按序号取色）
;;;   face-stack     多层 face 叠加（逐分量：后层覆盖前层，某层 #f 的分量不覆盖）
;;;
;;; 用 struct（#:prefab）：引擎的增量补丁用 (overlay . face) 编码，后端靠 pair? 区分
;;; overlay 与 face；prefab 形状的 face 不会被误当 overlay。

(provide (struct-out palette-color)
         (struct-out face-stack)
         face-compose face-layers)

(struct palette-color (kind index) #:prefab)
;; kind  : symbol          主题 palettes 里的调色板名
;; index : exact-integer   取模取第 index 项

(struct face-stack (layers) #:prefab)
;; layers : (listof face)，先应用的在前；后层覆盖前层

;; 把新 face 叠到旧 face 上（旧 #f = 空 → 直接是新 face，单层不上 stack）。
(define (face-compose old new)
  (cond
    [(not old) new]
    [(not new) old]
    [(face-stack? old) (face-stack (append (face-stack-layers old) (list new)))]
    [else (face-stack (list old new))]))

;; 取一格的层列表（#f → 空表；单 face → 单元素表）。
(define (face-layers f)
  (cond
    [(not f) '()]
    [(face-stack? f) (face-stack-layers f)]
    [else (list f)]))
