#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/selection.rkt"
         "../doc/buffer.rkt" "../doc/batch.rkt"
         "window.rkt" "layout.rkt" rackunit)

;;; viewport/rebase.rkt —— 编辑后 view 的重新基准（窗口同步机制的唯一实现）
;;;
;;; 编辑一次 = 一串 edit-desc（施加顺序）。每个 window 的**所有选区**都要过这串 desc：
;;;   free    每个选区端点随文本映射（落在被删区间 → 吸附删除起点），视口钉住不动。
;;;   leader  每个选区**坍缩到 head 并前进到插入之后**（edits-map-position 的零宽语义），
;;;           再 ensure primary 可见 —— 这是「编辑者」的光标行为。
;;;   follow  选区 + 视口锚点复制自 leader，再按自己几何 ensure。
;;;
;;; 关键次序：leader 必须**先 ensure-point 定稿**，follower 再复制它。

(provide rebase-free rebase-leader rebase-follow)

;; w : 待调整的 window；b* : 编辑后的新 buffer；descs : (listof edit-desc) 施加顺序
(define (rebase-free w b* descs)
  (define mapped
    (for/list ([s (in-list (window-selections w))])
      (for/fold ([s s]) ([d (in-list descs)]) (selection-map d s))))
  (window-set-selections (struct-copy window w [buffer b*]) mapped (window-primary w)))

;; 编辑者语义：选区坍缩到「经过全部 desc 之后」的 head，再 ensure primary 可见。
(define (rebase-leader w b* descs)
  (define mapped
    (for/list ([s (in-list (window-selections w))])
      (define p (edits-map-position descs (selection-head s)))
      (selection p p)))
  (window-ensure-point
   (window-set-selections (struct-copy window w [buffer b*]) mapped (window-primary w))))

;; w : 待调整的 window；leader : 编辑视图的最终 window（已 ensure）
(define (rebase-follow w leader)
  (window-ensure-point
   (struct-copy window w
     [buffer     (window-buffer leader)]
     [selections (window-selections leader)]
     [primary    (window-primary leader)]
     [top-line   (window-top-line leader)]
     [left-col   (window-left-col leader)]
     [top-seg    (window-top-seg leader)])))

;;; ---------- 测试（纯 window 级）----------

(module+ test
  (define b0 (buffer-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))

  ;; free：光标随编辑右移（插入点之后的字符）
  (define d-ins (edit-desc (point 0 0) (point 0 0) "XX"))
  (define b1 (let-values ([(b _) (buffer-apply-edit b0 d-ins)]) b))
  (define wf (window-set-point (window-open b0 3 10) (point 0 1)))
  (check-equal? (window-point (rebase-free wf b1 (list d-ins))) (point 0 3))

  ;; free：光标落在被删区间 → 吸附删除起点
  (define d-del (edit-desc (point 0 0) (point 1 0) ""))
  (define b2 (let-values ([(b _) (buffer-apply-edit b0 d-del)]) b))
  (check-equal? (window-point (rebase-free (window-set-point (window-open b0 3 10) (point 0 1)) b2 (list d-del)))
                (point 0 0))

  ;; free：多选区各自映射
  (define wm (window-set-selections (window-open b0 3 10)
                                    (list (selection (point 0 1) (point 0 1))
                                          (selection (point 1 0) (point 1 0)))))
  (check-equal? (map selection-head (window-selections (rebase-free wm b1 (list d-ins))))
                (list (point 0 3) (point 1 0)))

  ;; leader：光标前进到插入之后
  (check-equal? (window-point (rebase-leader (window-open b1 3 10) b1 (list d-ins)))
                (point 0 2))

  ;; follow：几何不同的视图，镜像 leader 选区后按自己几何 ensure
  (define leader (window-set-point (window-open b1 5 10) (point 4 0)))
  (define leader* (window-ensure-point leader))
  (define foll (rebase-follow (window-open b1 2 10) leader*))
  (check-equal? (window-point foll) (window-point leader*))
  (check-true (<= (window-top-line foll) 4
                  (+ (window-top-line foll) (sub1 (window-height foll)))))
  (check-eq? (window-buffer foll) (window-buffer leader*))

  (displayln "rebase.rkt: all tests passed"))
