#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/selection.rkt" "../atom/selection-set.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
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
;;;
;;; 注意：本层换的是 window 里的 **document**（文本 + 标注）；标注的移动在
;;; document-apply-change 里已经完成，这里只重定位光标/视口。

(provide rebase-free rebase-leader rebase-follow rebase-follow-viewport)

;; w : 待调整的 window；d* : 编辑后的新 document；descs : (listof edit-desc) 施加顺序
(define (rebase-free w d* descs)
  (struct-copy window w [document d*] [selection-set (selection-set-map-edit (window-selection-set w) descs)]))

;; 编辑者语义：选区坍缩到「经过全部 desc 之后」的 head，再 ensure primary 可见。
(define (rebase-leader w d* descs)
  (window-ensure-point
   (struct-copy window w [document d*] [selection-set (selection-set-advance-leader (window-selection-set w) descs)])))

;; w : 待调整的 window；leader : 编辑视图的最终 window（已 ensure）
(define (rebase-follow w leader)
  (window-ensure-point
   (struct-copy window w
     [document (window-document leader)]
     [selection-set    (window-selection-set leader)]
     [top-line (window-top-line leader)]
     [left-col (window-left-col leader)]
     [top-seg  (window-top-seg leader)])))

;; 视口镜像（**不**重新 ensure）：把 leader 的 document / 选区 / 视口锚点字面复制过来。
;;
;; 用于「以某 window 为准」的同步（editor-view-scroll / editor-view-follow）：leader 可能
;; 特意把光标滚出视口（window-scroll 只管视口、不管光标），若再按 follower 自己的光标
;; ensure，视口会被拉回一行 / 多行，导致同步窗口与被同步窗口错位。
(define (rebase-follow-viewport w leader)
  (struct-copy window w
    [document (window-document leader)]
    [selection-set (window-selection-set leader)]
    [top-line (window-top-line leader)]
    [left-col (window-left-col leader)]
    [top-seg  (window-top-seg leader)]))

;;; ---------- 测试（纯 window 级）----------

(module+ test
  (define d0 (document-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))

  ;; free：光标随编辑右移（插入点之后的字符）
  (define d-ins (edit-desc (point 0 0) (point 0 0) "XX"))
  (define d1 (let-values ([(d _) (document-apply-edit d0 d-ins)]) d))
  (define wf (window-set-point (window-open d0 3 10) (point 0 1)))
  (check-equal? (window-point (rebase-free wf d1 (list d-ins))) (point 0 3))

  ;; free：光标落在被删区间 → 吸附删除起点
  (define d-del (edit-desc (point 0 0) (point 1 0) ""))
  (define d2 (let-values ([(d _) (document-apply-edit d0 d-del)]) d))
  (check-equal? (window-point (rebase-free (window-set-point (window-open d0 3 10) (point 0 1)) d2 (list d-del)))
                (point 0 0))

  ;; free：多选区各自映射
  (define wm (window-set-selections (window-open d0 3 10)
                                    (list (selection (point 0 1) (point 0 1))
                                          (selection (point 1 0) (point 1 0)))))
  (check-equal? (map selection-head (window-selections (rebase-free wm d1 (list d-ins))))
                (list (point 0 3) (point 1 0)))

  ;; leader：光标前进到插入之后
  (check-equal? (window-point (rebase-leader (window-open d1 3 10) d1 (list d-ins)))
                (point 0 2))

  ;; follow：几何不同的视图，镜像 leader 选区后按自己几何 ensure
  (define leader (window-set-point (window-open d1 5 10) (point 4 0)))
  (define leader* (window-ensure-point leader))
  (define foll (rebase-follow (window-open d1 2 10) leader*))
  (check-equal? (window-point foll) (window-point leader*))
  (check-true (<= (window-top-line foll) 4
                  (+ (window-top-line foll) (sub1 (window-height foll)))))
  (check-eq? (window-document foll) (window-document leader*))

  ;; follow-viewport：字面镜像视口，**不**按 follower 光标重新 ensure
  ;; （leader 特意把光标滚出视口时，视口不得被拉回）
  (define lv (struct-copy window (window-ensure-point (window-open d1 3 10))
                          [top-line 4]))
  (define fv* (rebase-follow-viewport (window-open d1 3 10) lv))
  (check-equal? (window-top-line fv*) 4)
  (check-equal? (window-point fv*) (window-point lv))          ; 选区仍复制自 leader
  (check-equal? (window-top-seg fv*) (window-top-seg lv))
  (check-equal? (window-left-col fv*) (window-left-col lv))

  (displayln "rebase.rkt: all tests passed"))
