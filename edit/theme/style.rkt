#lang racket

;;; edit/theme/style.rkt —— edit 自己的样式值模型（纯，不依赖任何后端）
;;;
;;;   rgb   : 真彩色分量，各 0-255
;;;   style : fg / bg 真彩色 + **按需**属性列表（没写的属性不产生任何转义）
;;;
;;; 这是 edit 的配置词汇，对齐 lab-rebuild 的 theme 思路（真彩色，后端不参与）：
;;; 颜色只存数据，后端（如 tui.rkt）负责翻成自己的转义序列。换后端只换翻译。

(provide (struct-out rgb) (struct-out style))

;;; ---------- 真彩色 ----------

(struct rgb (r g b)
  #:transparent
  #:guard (lambda (r g b name)
            (for ([v (in-list (list r g b))] [n (in-list '("r" "g" "b"))])
              (unless (byte? v) (error name "~a 必须是 0-255: ~a" n v)))
            (values r g b)))

;;; ---------- 按需属性 ----------

;; 属性词汇；未列出的名字后端忽略。输出顺序跟这个列表一致。
(define known-attrs '(bold dim italic underline blink reverse))
(define (style-attrs-known? attrs)
  (for/and ([a (in-list attrs)]) (and (memq a known-attrs) #t)))

;;; ---------- style ----------

;; (style fg bg attrs)：fg/bg = rgb | #f；attrs = known-attrs 的子集（可 '()）。
(struct style (fg bg attrs)
  #:transparent
  #:guard (lambda (fg bg attrs name)
            (unless (or (not fg) (rgb? fg)) (error name "fg 必须是 rgb 或 #f: ~a" fg))
            (unless (or (not bg) (rgb? bg)) (error name "bg 必须是 rgb 或 #f: ~a" bg))
            (unless (and (list? attrs) (style-attrs-known? attrs))
              (error name "attrs 只能是 ~a 的子集: ~a" known-attrs attrs))
            (values fg bg (remove-duplicates attrs))))
