#lang racket

;;; edit-tui/base/face.rkt —— face 结构 + 读 / 写操作（纯值）
;;;
;;; core 的 face 端口存 `#f`（默认，整轨惰性）或一个 face。face 三分量：
;;;
;;;     fg    : #f | symbol     前景分量
;;;     bg    : #f | symbol     背景分量
;;;     attrs : (listof symbol) 属性分量（bold / italic / underline …）
;;;
;;; 分量值都是**符号**：怎么解释由后端决定（后端把这些符号当 tui 风格名，
;;; 用 style->bytes 取转义序列）。core 侧只有符号，没有颜色 / 属性结构。
;;;
;;; 本模块只定义**结构 + 读 / 写操作**，**不提供任何「合并两个 face」的策略**：
;;; 要叠加就由写的一方（插件）自己读出来、只改要改的分量、再写回；
;;; 保留还是覆盖由它决定。于是「只写 bg 的插件」= 读旧 face，face-set-bg，写回。
;;;
;;; 用 #:prefab：patch.rkt 用 `(overlay . face)` 编码 overlay，后端靠 pair? 区分，
;;; 所以 face 不能是 pair；prefab struct 保证这点，且 equal? 可用。

(provide (struct-out face)       ; 构造 face / 谓词 face? / 读 face-fg face-bg face-attrs
         face-empty
         face-set-fg face-set-bg face-set-attrs
         face-add-attr face-remove-attr
         face-attrs?)            ; 某属性在不在

(struct face (fg bg attrs) #:prefab)
;; fg/bg : #f | symbol
;; attrs : (listof symbol)

;; 空 face（三分量全默认）。`#f` 也代表默认 —— 写操作两者都收。
(define face-empty (face #f #f '()))

;;; ---------- 写（纯，返回新 face；接受 #f 或 face） ----------

(define (face-set-fg f v)
  (if f (struct-copy face f [fg v]) (face v #f '())))

(define (face-set-bg f v)
  (if f (struct-copy face f [bg v]) (face #f v '())))

(define (face-set-attrs f v)
  (if f (struct-copy face f [attrs v]) (face #f #f v)))

;; 加 / 去一个属性（幂等，保持顺序）。
(define (face-add-attr f a)
  (define f* (or f face-empty))
  (if (memq a (face-attrs f*))
      f*
      (face-set-attrs f* (append (face-attrs f*) (list a)))))

(define (face-remove-attr f a)
  (and f (face-set-attrs f (remq a (face-attrs f)))))

;;; ---------- 读 ----------

(define (face-attrs? f a) (and f (and (memq a (face-attrs f)) #t)))

(module+ main
  (require rackunit)
  ;; 构造 / 读
  (define f (face 'kw 'bg1 '(bold)))
  (check-equal? (face-fg f) 'kw)
  (check-equal? (face-bg f) 'bg1)
  (check-equal? (face-attrs f) '(bold))
  ;; 写：#f 也收
  (check-equal? (face-set-bg #f 'depth-2) (face #f 'depth-2 '()))
  (check-equal? (face-set-fg (face 'a 'b '()) 'c) (face 'c 'b '()))
  ;; 只改 bg，fg 保留（插件读改写）
  (check-equal? (face-set-bg (face 'kw #f '()) 'depth-2) (face 'kw 'depth-2 '()))
  ;; attrs 幂等
  (check-equal? (face-add-attr (face-add-attr #f 'bold) 'bold) (face #f #f '(bold)))
  (check-equal? (face-remove-attr (face #f #f '(bold italic)) 'bold)
                (face #f #f '(italic)))
  ;; 不是 pair（overlay 编码可区分）
  (check-false (pair? (face 'a 'b '())))
  (displayln "face.rkt: ok"))
