#lang racket

;;; edit3/face.rkt —— 带参 face 值 + 分层（纯）
;;;
;;; 普通 face 是 symbol（theme 里查固定 style）。需要分层叠加时用 face-stack：
;;; 多层 face 逐分量组合（后层覆盖前层，某层 #f 的分量不覆盖）。
;;; 用 struct（#:prefab）：引擎增量补丁用 (overlay . face) 编码，后端靠 pair? 区分 overlay
;;; 与 face；prefab 形状的 face 不会被误当 overlay。

(provide (struct-out face-stack) face-compose face-layers
         face-runs)

(struct face-stack (layers) #:prefab)   ; layers : (listof face)，先应用的在前

;; 把新 face 叠到旧 face 上（旧 #f = 空 → 直接新 face，单层不 stack）。
(define (face-compose old new)
  (cond
    [(not old) new]
    [(not new) old]
    [(face-stack? old) (face-stack (append (face-stack-layers old) (list new)))]
    [else (face-stack (list old new))]))

;; 取一格的层（#f → 空表；单 face → 单元素表）。
(define (face-layers f)
  (cond
    [(not f) '()]
    [(face-stack? f) (face-stack-layers f)]
    [else (list f)]))

;; 一行 face 向量 → 连续同 face 区间 (list start end face)，face 非 #f。
(define (face-runs vec)
  (define n (vector-length vec))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [else
       (define f (vector-ref vec i))
       (define j (let next ([j (add1 i)])
                   (if (and (< j n) (equal? (vector-ref vec j) f)) (next (add1 j)) j)))
       (loop j (if f (cons (list i j f) acc) acc))])))
