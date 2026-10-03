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
  (hash 'line-number      (style '(110 115 130) #f #f #f #f #f)
        'status           (style '(230 230 230) '(40 44 52) #f #f #f #f)
        'separator        (style '(80 85 95) #f #f #f #f #f)
        ;; 两棵树
        'tree-dir         (style '(120 180 240) #f #t #f #f #f)   ; 目录（蓝、粗）
        'tree-file        (style '(190 190 200) #f #f #f #f #f)   ; 文件（灰）
        'tree-open        (style '(90 220 120) #f #f #f #f #f)    ; 已打开的文件（绿）
        'tree-doc         (style '(225 225 235) #f #t #f #f #f)   ; 文档
        'tree-view        (style '(170 170 185) #f #f #f #f #f)   ; 视图
        'tree-view-active (style '(255 214 120) #f #t #f #f #f))) ; 焦点视图（黄）

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
