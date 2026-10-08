#lang racket

;;; lab-re-rebuild/kernel/face.rkt —— 需要带参数的 face 值 + 前景/背景分层。
;;;
;;; core 的 face 是不透明值（core 不解释），由主题解释。普通 face 用 symbol；
;;; 需要参数（括号按深度、词按词）时用这里的结构体。
;;;
;;; ⚠ 用 struct（#:prefab）：渲染补丁用 (overlay . face) 编码，后端靠 pair? 区分 overlay
;;;   和 face；pair 形状的 face 会被误当 overlay。prefab 还能跨 place 序列化。

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
