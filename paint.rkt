#lang racket

(require "cursor.rkt" "buffer.rkt" "window.rkt" "render.rkt"
         "width.rkt" "screen.rkt" rackunit)

;;; paint.rkt —— 把 buffer + window 的可见区渲染成 screen
;;;
;;; 只渲染可见区（height 行），不碰整个 buffer（大文件友好）。
;;; 每帧全量重画可见区；增量绘制交给 screen-diff / 后端。
;;; 宽字符只做「列」几何：run.col 是显示列，run.text 是原字符，
;;; 终端/GUI 自己把宽字符显示成 2 列。

(provide paint)

(define (paint w)
  (define b (window-buffer w))
  (define top (window-top-line w))
  (define height (window-height w))
  (define width (window-width w))
  (define left-col (window-left-col w))
  (define n (buffer-line-count b))

  (define row-runs
    (for/vector ([vi (in-range height)])
      (define li (+ top vi))
      (if (< li n)
          (line->runs b li left-col width)
          '())))

  ;; 光标：point 换算成显示坐标（列要过 width.rkt）
  (define p (buffer-point b))
  (define cur-row (- (cursor-line p) top))
  (define cur-col
    (- (index->column (buffer-line-ref b (cursor-line p))
                      (cursor-col p))
       left-col))

  (screen height width row-runs cur-row cur-col))

;; 一行 glyphs → 可见 runs（跳过 left-col 左侧，clip 到 width）
(define (line->runs b li left-col width)
  (define glyphs (rendered-line-glyphs (render-line b li)))
  (define n (vector-length glyphs))
  ;; 1) 收集可见 cell：(col ch face)
  (define cells
    (let loop ([i 0] [col 0] [acc '()])
      (cond
        [(>= i n) (reverse acc)]
        [else
         (define g (vector-ref glyphs i))
         (define ch (glyph-ch g))
         (define face (glyph-face g))
         (define w (char-display-width ch))
         (define end (+ col w))
         (cond
           [(< end left-col) (loop (add1 i) end acc)]               ; 全在左外
           [(>= col (+ left-col width)) (reverse acc)]              ; 已出右界
           [(and (< col left-col) (> w 1)) (loop (add1 i) end acc)] ; 宽字符被左切，丢弃
           [(> end (+ left-col width)) (loop (add1 i) end acc)]     ; 宽字符出右界，丢弃
           [else
            (loop (add1 i) end
                  (cons (list (- col left-col) ch face) acc))])])))
  ;; 2) 按 face 分组（同 face 且列连续 → 合并）
  (cells->runs cells))

(define (cells->runs cells)
  (define-values (runs cur)
    (for/fold ([runs '()] [cur #f])
              ([c (in-list cells)])
      (match-define (list col ch face) c)
      (cond
        [(and cur
              (equal? face (run-face cur))
              (= (+ (run-col cur) (string-display-width (run-text cur))) col))
         (values runs (struct-copy run cur
                       [text (string-append (run-text cur) (string ch))]))]
        [else
         (values (if cur (cons cur runs) runs)
                 (run col (string ch) face))])))
  (reverse (if cur (cons cur runs) runs)))

(module+ test
  ;; 基本：一行 "a中b"，无属性 → 单个 run，光标在 (0,0)
  (define b0 (buffer-open "a中b\nc"))
  (define w0 (window-open b0 2 10))
  (define s0 (paint w0))
  (check-equal? (vector-ref (screen-row-runs s0) 0)
                (list (run 0 "a中b" (hash))))
  (check-equal? (vector-ref (screen-row-runs s0) 1)
                (list (run 0 "c" (hash))))
  (check-equal? (screen-cursor-row s0) 0)
  (check-equal? (screen-cursor-col s0) 0)

  ;; 光标在 "中" 之后：列 = a(1) + 中(2) = 3
  (define b1 (buffer-goto b0 0 2))
  (define s1 (paint (window-open b1 2 10)))
  (check-equal? (screen-cursor-col s1) 3)

  ;; 水平滚动：left-col=2 时 "中" 的左半被切，整字丢弃（列 0 留空），b 在列 1
  (define w2 (window-set-left (window-open b0 2 10) 2))
  (define s2 (paint w2))
  (check-equal? (vector-ref (screen-row-runs s2) 0)
                (list (run 1 "b" (hash))))

  ;; 右界裁剪：width=3，放得下 a(1)+中(2)，放不下 b
  (define w3 (window-open b0 2 3))
  (define s3 (paint w3))
  (check-equal? (vector-ref (screen-row-runs s3) 0)
                (list (run 0 "a中" (hash))))

  ;; 属性分段：bold 属性把一行拆成两个 run
  (define b2 (buffer-put-text-property b0 0 0 1 'face 'bold))
  (define s4 (paint (window-open b2 2 10)))
  (check-equal? (vector-ref (screen-row-runs s4) 0)
                (list (run 0 "a" (hash 'face 'bold))
                      (run 1 "中b" (hash))))

  (displayln "paint.rkt: all tests passed"))
