#lang racket

;;; app/status.rkt —— 状态栏文本投影（纯派生 + 一次不纯同步）
;;;
;;; 状态栏内容 = 焦点 view 的**行列** + 焦点 buffer 的**路径**（若有）
;;;              + **键序列**（world.pending，优先）/ 否则 world.status。
;;;
;;; status-line 是纯投影；status-sync!（不纯，loop 每帧调）把它写进槽的 'status member。

(require racket/string
         "../../core/editor.rkt"
         "../layout/main.rkt"
         "../command/main.rkt"
         "world.rkt"
         "resource.rkt"
         "slot.rkt")

(provide status-line status-sync!
         status-position status-path status-sequence)

;; 状态栏要报告的 view：焦点在槽（chrome）上时用第一个 'editor view，
;; 否则用焦点 view。否则移动状态栏光标会改变“状态行”自身 → 每帧重写 → 滚动被重置。
(define (status-view w)
  (define fv (world-focus-view w))
  (if (slot-focused? w)
      (or (for/first ([l (in-list (tree-visible-leaves (world-layout w)))]
                      #:when (and (eq? (leaf-role l) 'editor) (leaf-view l)))
            (leaf-view l))
          fv)
      fv))

;; 报告 view 的 (行 . 列)，1-based；无 → #f。
(define (status-position w)
  (define v (status-view w))
  (and v (cons (add1 (view-point-line v)) (add1 (view-point-column v)))))

;; 报告 view 的 buffer 路径（内存文档没有 → #f）。
(define (status-path w)
  (define v (status-view w))
  (and v (buffer-path (view-buffer v))))

;; 正在输入的键序列（world.pending）；没有 → #f。
(define (status-sequence w)
  (define p (world-pending w))
  (and (pair? p) (string-join (map key->string p) " ")))

;; 纯投影：位置 路径 (键序列 | 状态消息)，空段省略。
(define (status-line w)
  (define pos (status-position w))
  (string-join
   (for/list ([s (in-list (list (and pos (format "~a:~a" (car pos) (cdr pos)))
                                (status-path w)
                                (or (status-sequence w) (world-status w))))]
              #:when (and s (positive? (string-length s))))
     s)
   "  "))

;; 不纯：把投影镜像进 'status member 的 buffer。
(define (status-sync! w)
  (define v (slot-member w 'status))
  (when v
    (define b (view-buffer v))
    (define s (status-line w))
    (unless (string=? (buffer-string b) s)
      (buffer-set-document! b s))))
