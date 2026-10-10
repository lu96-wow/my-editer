#lang racket

;;; edit/core/popup.rkt —— 浮层（补全 / 文档）尺寸与落位（纯几何）
;;;
;;; 把「弹窗多大、摆哪」从业务里拆出来，规则集中定义，业务只给「想要多大」和锚点。
;;; 纯函数：输入全是数字，不认识 session / editor，便于测试。
;;;
;;; 词汇：
;;;   anchor-row / anchor-col   输入光标（正在输入处）的**绝对屏幕**行 / 列
;;;   screen-w / screen-h       屏幕（终端）宽 / 高
;;;   want-w / want-h           内容希望的宽 / 高
;;;
;;; 尺寸规则
;;;   · 宽：want-w 钳到 [1, screen-w]。
;;;   · 高：**不遮挡锚点行时可用的最大高度** = max(锚点上方行数, 下方行数)；
;;;         want-h 再钳到该上界（不够就截断）。
;;;
;;; 落位规则（硬约束：弹窗矩形与锚点行**不相交** —— 正在输入的那行永远可见）
;;;   1) 锚点下方放得下（h ≤ below）→ 贴在锚点下一行（top = anchor-row + 1）；
;;;   2) 否则上方放得下（h ≤ above）→ 贴在锚点上一行（bottom = anchor-row）；
;;;   3) 两侧都不够时，高度已在「尺寸」步钳到较大的一侧，故 1/2 必居其一。
;;;   · 水平：左对齐锚点列，钳到屏内（右边缘不越界）。
;;;
;;; 于是「上方空间不足却把菜单顶到 0、盖住光标行」这类问题在几何层被排除。
;;;
;;; 两个浮窗（如补全菜单 + 文档窗）用 popup-rect 定主窗、popup-rect-avoiding 定次窗；
;;; 两者互不重叠，且都不遮挡锚点行。

(provide popup-above popup-below popup-space popup-max-h
         popup-window popup-rect popup-rect-avoiding)

;;; ---------- 空间 ----------

;; 锚点行上方（不含锚点行）可用行数。
(define (popup-above anchor-row) (max 0 anchor-row))

;; 锚点行下方（不含锚点行）可用行数。
(define (popup-below anchor-row screen-h) (max 0 (- screen-h (add1 anchor-row))))

;; → (values above below)
(define (popup-space anchor-row screen-h)
  (values (popup-above anchor-row) (popup-below anchor-row screen-h)))

;; 不遮挡锚点行时的高度上界（取两侧较大者）。
(define (popup-max-h anchor-row screen-h)
  (define-values (above below) (popup-space anchor-row screen-h))
  (max above below))

;;; ---------- 内容窗口 ----------

;; n 项里以 idx 为中心、最多 cap 行的窗口（至少 1 行，最多 n 行）。
;; → (values start rows)
(define (popup-window n idx cap)
  (define rows (max 1 (min n (max 1 cap))))
  (values (max 0 (min (- idx (quotient rows 2)) (- n rows))) rows))

;;; ---------- 矩形 ----------

;; want-w × want-h 的弹窗摆在锚点旁。返回**实际** (values x y w h)（已钳）。
;; 保证：矩形 [y, y+h) 不包含 anchor-row。
(define (popup-rect anchor-row anchor-col want-w want-h screen-w screen-h)
  (define max-h (popup-max-h anchor-row screen-h))
  (define w (max 1 (min (max 1 want-w) screen-w)))
  (define h (max 0 (min want-h max-h)))
  (define x (max 0 (min anchor-col (max 0 (- screen-w w)))))
  (define below (popup-below anchor-row screen-h))
  (define y (if (<= h below)
                (add1 anchor-row)              ; 下方：top = 锚点下一行
                (- anchor-row h)))             ; 上方：bottom = 锚点行
  (values x y w h))

;;; ---------- 次窗（避让主窗） ----------

;; want-w × want-h 的次窗，摆在锚点旁，且**不与主窗矩形相交**、不遮挡锚点行。
;; 主窗矩形 (ax ay aw ah)（由 popup-rect 得出，故也在锚点某一侧）。
;;
;; 策略：
;;   1) 主窗在锚点下方 → 次窗优先放**锚点上方**；主窗在上方 → 次窗优先放**锚点下方**
;;      （两窗分列光标两侧，都可见）；
;;   2) 优先侧放不下整窗 → 看主窗**外侧**堆叠（主下→次更下 / 主上→次更上）；
;;   3) 两侧都放不下整窗 → 取空间较大的一侧，高度钳到该侧可用行数（可为 0）。
;; 水平规则同 popup-rect。返回实际 (values x y w h)。
(define (popup-rect-avoiding anchor-row anchor-col want-w want-h screen-w screen-h
                             ax ay aw ah)
  (define w (max 1 (min (max 1 want-w) screen-w)))
  (define x (max 0 (min anchor-col (max 0 (- screen-w w)))))
  (define primary-below? (> ay anchor-row))
  ;; opp = 锚点另一侧（与主窗相对）；stack = 主窗外侧
  (define opp (if primary-below? (popup-above anchor-row) (popup-below anchor-row screen-h)))
  (define stack (if primary-below?
                    (max 0 (- screen-h (+ ay ah)))
                    (max 0 ay)))
  (define (place-opp h)
    (if primary-below?
        (values x (- anchor-row h) w h)          ; 锚点上方
        (values x (add1 anchor-row) w h)))       ; 锚点下方
  (define (place-stack h)
    (if primary-below?
        (values x (+ ay ah) w h)                 ; 主窗更下
        (values x (- ay h) w h)))                ; 主窗更上
  (cond
    [(>= opp want-h) (place-opp want-h)]
    [(>= stack want-h) (place-stack want-h)]
    [(>= stack opp) (place-stack (min want-h stack))]
    [else (place-opp (min want-h opp))]))
