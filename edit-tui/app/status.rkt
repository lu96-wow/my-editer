#lang racket

;;; app/status.rkt —— 状态栏文本投影（纯派生 + 一次不纯同步）
;;;
;;; 状态栏内容 = 焦点 view 的**行列** + 焦点 buffer 的**路径**（若有）
;;;              + **键序列**（world.pending，优先）/ 否则 world.status。
;;;
;;; status-line 是纯投影；status-sync!（不纯，loop 每帧调）把它写进槽的 'status member。

(require racket/string
         "../../core/editor.rkt"
         "../command/main.rkt"
         "world.rkt"
         "resource.rkt"
         "slot.rkt")

(provide status-line status-sync!
         status-position status-path status-sequence)

;; 焦点 view 的 (行 . 列)，1-based；无焦点 → #f。
(define (status-position w)
  (define v (world-focus-view w))
  (and v (cons (add1 (view-point-line v)) (add1 (view-point-column v)))))

;; 焦点 buffer 的路径（内存文档没有 → #f）。
(define (status-path w)
  (define v (world-focus-view w))
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
