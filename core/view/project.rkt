#lang racket

(require "../text/buffer.rkt" "window.rkt" "screen.rkt" "view.rkt" rackunit)

;;; project.rkt —— 把 window 的可见区投影成 screen（纯函数，无副作用）
;;;
;;; 布局（clip/wrap → vrow 序列）由 view.rkt 提供；这里只把 vrow 序列
;;; 渲染成 runs，再装进 screen。真正的「绘制到介质」在 core 之外（后端）。
;;;
;;; 名字用 window->screen：与 window-point->screen、content->string 同族，
;;; 一眼看出是 window → screen 的投影。

(provide window->screen)

(define (window->screen w)
  (define b (window-buffer w))
  (define vrows (window-vrows w))
  (define row-runs
    (for/vector ([vr (in-vector vrows)])
      (if (and (>= (vrow-line vr) 0)
               (< (vrow-start-col vr) (vrow-end-col vr)))
          (line-range->runs b (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr))
          '())))
  (define-values (cur-row cur-col) (window-point->screen w))
  (screen (window-height w) (window-width w) row-runs
          (or cur-row -1) (or cur-col -1)))

(module+ test
  ;; clip 模式（沿用原测试）
  (define b0 (buffer-open "a中b\nc"))
  (define w0 (window-open b0 2 10))
  (define s0 (window->screen w0))
  (check-equal? (vector-ref (screen-row-runs s0) 0)
                (list (run 0 "a中b" (hash))))
  (check-equal? (vector-ref (screen-row-runs s0) 1)
                (list (run 0 "c" (hash))))
  (check-equal? (screen-cursor-row s0) 0)
  (check-equal? (screen-cursor-col s0) 0)

  (define-values (w1 _) (window-goto (window-open b0 2 10) 0 2))
  (check-equal? (screen-cursor-col (window->screen w1)) 3)

  (define s2 (window->screen (window-set-left (window-open b0 2 10) 2)))
  (check-equal? (vector-ref (screen-row-runs s2) 0) (list (run 1 "b" (hash))))

  (define s3 (window->screen (window-open b0 2 3)))
  (check-equal? (vector-ref (screen-row-runs s3) 0) (list (run 0 "a中" (hash))))

  ;; 属性分段
  (define b2 (buffer-put-text-property b0 0 0 1 'face 'bold))
  (define s4 (window->screen (window-open b2 2 10)))
  (check-equal? (vector-ref (screen-row-runs s4) 0)
                (list (run 0 "a" (hash 'face 'bold))
                      (run 1 "中b" (hash))))

  ;; wrap 模式："中中中"（宽 6）折宽 4 → 两段 + "x"
  (define b3 (buffer-open "中中中\nx"))
  (define ww (window-set-mode (window-open b3 3 4) 'wrap))
  (define sw (window->screen ww))
  (check-equal? (vector-ref (screen-row-runs sw) 0) (list (run 0 "中中" (hash))))
  (check-equal? (vector-ref (screen-row-runs sw) 1) (list (run 0 "中" (hash))))
  (check-equal? (vector-ref (screen-row-runs sw) 2) (list (run 0 "x" (hash))))

  (displayln "project.rkt: all tests passed"))
