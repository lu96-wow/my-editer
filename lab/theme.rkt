#lang racket

;;; lab/theme.rkt —— face / overlay → style（纯数据）
;;;
;;; core 的 face 是不透明值；只有这里知道它对应什么颜色。后端拿到的是 style（RGB），
;;; 再由后端自己变成终端真彩色 / 画布颜色。
;;;
;;; overlay（cursor / selection）在 face 的 style 之上叠一层。

(require "output.rkt")

(provide face->style overlay-style attr->style theme)

;; face → 基础 style（fg/bg/attrs）。加一种 face 只改这张表。
(define theme
  (hash 'line-number      (style* #:fg '(110 115 130))
        'status           (style* #:fg '(230 230 230) #:bg '(40 44 52))
        'separator        (style* #:fg '(80 85 95))
        ;; 两棵树
        'tree-dir         (style* #:fg '(120 180 240) #:bold? #t)      ; 目录（蓝、粗）
        'tree-file        (style* #:fg '(190 190 200))                  ; 文件（灰）
        'tree-open        (style* #:fg '(90 220 120))                   ; 已打开的文件（绿）
        'tree-doc         (style* #:fg '(225 225 235) #:bold? #t)      ; 文档
        'tree-view        (style* #:fg '(170 170 185))                  ; 视图
        'tree-view-active (style* #:fg '(255 214 120) #:bold? #t)))    ; 焦点视图（黄）

(define (face->style face)
  (if (and face (hash-has-key? theme face))
      (hash-ref theme face)
      default-style))

;; overlay：光标 = 反显；选中 = 蓝色底。其余透传。
(define (overlay-style channel st)
  (case channel
    [(cursor)    (struct-copy style st [reverse? #t])]
    [(selection) (struct-copy style st [bg '(58 74 128)])]
    [else st]))

;; core piece 的 attr → style。attr = (channel . face)（已由 output.rkt 归一）或裸 face。
(define (attr->style attr)
  (cond
    [(not (pair? attr)) (face->style attr)]
    [else (overlay-style (car attr) (face->style (cdr attr)))]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (check-equal? (face->style 'line-number) (style '(110 115 130) #f #f #f #f #f))
  (check-equal? (face->style 'unknown) default-style)

  ;; 光标在 face 上叠反显
  (define cs (attr->style (cons 'cursor 'line-number)))
  (check-true (style-reverse? cs))
  (check-equal? (style-fg cs) '(110 115 130))

  ;; 选中叠蓝底
  (define ss (attr->style (list 'selection #f)))
  (check-equal? (style-bg ss) '(58 74 128))

  ;; render 透传 face（output 归一后 render 也是 (render . face)）
  (check-equal? (attr->style (cons 'render 'tree-dir)) (face->style 'tree-dir))

  (displayln "lab/theme.rkt: all tests passed"))
