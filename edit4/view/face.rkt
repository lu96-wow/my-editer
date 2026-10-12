#lang racket

;;; edit4/view/face.rkt —— 带参 face 值 + 分层（纯）
;;;
;;; 普通 face = 符号（theme 里查固定 style）。需分层叠加时用 face-stack（后层覆盖分量）。
;;; palette-color / palette-bg 按位置取调色板颜色。
;;; 用 #:prefab：引擎增量补丁用 (cursor . face) / (selection . face) 编码，后端靠 pair? 区分。

(provide (struct-out face-stack) (struct-out palette-color) (struct-out palette-bg)
         face-compose face-layers face-runs)

(struct face-stack (layers) #:prefab)      ; layers : (listof face)，先应用的在前
(struct palette-color (kind index) #:prefab)
(struct palette-bg (kind index) #:prefab)

;; 把新 face 叠到旧 face 上（旧 #f = 空）。
(define (face-compose old new)
  (cond
    [(not old) new]
    [(not new) old]
    [(face-stack? old) (face-stack (append (face-stack-layers old) (list new)))]
    [else (face-stack (list old new))]))

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
