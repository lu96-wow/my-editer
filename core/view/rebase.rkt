#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt"
         "window.rkt" "view.rkt" rackunit)

;;; rebase.rkt —— 编辑后 view 的重新基准（窗口同步机制的唯一实现）
;;;
;;; 两种模式（与 view 的 sync 字段对应）：
;;;   free   光标随文本映射（落在被删区间 → 吸附删除起点），视口钉住不动。
;;;          正确性下限：光标不指向别的文本。
;;;   follow 光标 + 视口锚点复制自 leader，**再按自己的几何 ensure-point**。
;;;          几何与 leader 相同 → 完全 lockstep；不同 → 跟着光标、视口自己夹紧，
;;;          不会把光标丢到自己可见区之外。
;;;
;;; 关键次序：leader 必须是**已经 ensure-point 定稿**的 window，follower 才复制它；
;;; 否则 follower 复制到滚动前的旧锚点（差一行 / 只跟下滚不跟上滚）。

(provide rebase-free rebase-follow)

;; w : 待调整的 window；b* : 编辑后的新 buffer；d : 生效 edit-desc
(define (rebase-free w b* d)
  (define p (window-point w))
  (define p* (or (edit-desc-map-position d p) (edit-desc-start d)))
  (window-set-point (window-set-buffer w b*) p*))

;; w : 待调整的 window；leader : 编辑视图的最终 window（已 ensure）
(define (rebase-follow w leader)
  (window-ensure-point
   (struct-copy window w
     [buffer   (window-buffer leader)]
     [point    (window-point leader)]
     [top-line (window-top-line leader)]
     [left-col (window-left-col leader)]
     [top-seg  (window-top-seg leader)])))

;;; ---------- 测试（纯 window 级）----------

(module+ test
  (define b0 (buffer-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))

  ;; free：光标随编辑右移（插入点之后的字符）
  (define d-ins (edit-desc (point 0 0) (point 0 0) "XX"))
  (define b1 (let-values ([(b _) (buffer-apply-edit b0 d-ins)]) b))
  (define wf (window-goto (window-open b0 3 10) 0 1))
  (check-equal? (window-point (rebase-free wf b1 d-ins)) (point 0 3))

  ;; free：光标落在被删区间 → 吸附删除起点
  (define d-del (edit-desc (point 0 0) (point 1 0) ""))
  (define b2 (let-values ([(b _) (buffer-apply-edit b0 d-del)]) b))
  (check-equal? (window-point (rebase-free (window-goto (window-open b0 3 10) 0 1) b2 d-del))
                (point 0 0))

  ;; follow：几何不同的视图，镜像 leader 光标后按自己几何 ensure
  (define leader (window-goto (window-open b1 5 10) 4 0))
  (define leader* (window-ensure-point leader))
  (define foll (rebase-follow (window-open b1 2 10) leader*))
  (check-equal? (window-point foll) (window-point leader*))
  (check-true (<= (window-top-line foll) 4
                  (+ (window-top-line foll) (sub1 (window-height foll)))))
  (check-eq? (window-buffer foll) (window-buffer leader*))

  (displayln "rebase.rkt: all tests passed"))
