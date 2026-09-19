#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "window.rkt" "screen.rkt" "view.rkt" rackunit)

;;; project.rkt —— 把 window 的可见区投影成 screen（纯函数）
;;;
;;; 布局（clip/wrap → vrow 序列）由 view.rkt 提供；这里只把 vrow 渲染成 runs、
;;; 装进 screen，并把光标位置算出来。真正的绘制在 core 之外（后端）。

(provide window->screen)

(define (window->screen w)
  (define b (window-buffer w))
  (define vrows (window-vrows w))
  (define row-runs
    (for/vector ([vr (in-vector vrows)])
      (if (and (>= (vrow-line vr) 0) (< (vrow-start-col vr) (vrow-end-col vr)))
          (line-range->runs b (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr))
          '())))
  (define-values (cur-row cur-col) (window-point->screen w))
  (screen (window-height w) (window-width w) row-runs (or cur-row -1) (or cur-col -1)))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "a中b\nc"))

  (define s0 (window->screen (window-open b0 2 10)))
  (check-equal? (vector-ref (screen-row-runs s0) 0) (list (run 0 "a中b" (hash))))
  (check-equal? (vector-ref (screen-row-runs s0) 1) (list (run 0 "c" (hash))))
  (check-equal? (screen-cursor-row s0) 0)
  (check-equal? (screen-cursor-col s0) 0)

  ;; 光标显示列
  (check-equal? (screen-cursor-col (window->screen (window-set-point (window-open b0 2 10) (point 0 2)))) 3)

  ;; 水平吸附：left=2 落在「中」右半 → 吸附到 3（'b' 的起点）
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-set-left (window-open b0 2 10) 2))) 0)
                (list (run 0 "b" (hash))))

  ;; 属性分段
  (define b2 (buffer-put-property b0 (point 0 0) (point 0 1) 'face 'bold))
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open b2 2 10))) 0)
                (list (run 0 "a" (hash 'face 'bold)) (run 1 "中b" (hash))))

  ;; wrap
  (define sw (window->screen (window-set-mode (window-open (buffer-open "中中中\nx") 3 4) 'wrap)))
  (check-equal? (vector-ref (screen-row-runs sw) 0) (list (run 0 "中中" (hash))))
  (check-equal? (vector-ref (screen-row-runs sw) 1) (list (run 0 "中" (hash))))
  (check-equal? (vector-ref (screen-row-runs sw) 2) (list (run 0 "x" (hash))))

  ;; 约束不进 face
  (define b5 (buffer-put-restrict (buffer-put-property (buffer-open "abcdef") (point 0 0) (point 0 6) 'face 'bold)
                                  (point 0 3) (point 0 6) (restrict #t)))
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open b5 1 10))) 0)
                (list (run 0 "abcdef" (hash 'face 'bold))))

  (displayln "project.rkt: all tests passed"))
