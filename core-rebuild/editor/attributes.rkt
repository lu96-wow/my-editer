#lang racket

;;; editor/attributes.rkt —— 端口（face / readonly）+ 槽 的写回（按 buffer）
;;;
;;; 写回就地改 document 的端口盒 / 槽（不换 document、不记步、不动 history）。

(require "state.rkt"
         "../text/document.rkt"
         "../text/base/range.rkt" "../text/base/point.rkt"
         "../text/base/line.rkt" "../text/base/track.rkt")

(provide
 ;; ---------- 端口 ----------
 buffer-set-face!                 ; buffer face → void（整轨设）
 buffer-set-readonly!             ; buffer flag → void（整轨设）
 buffer-face-range!               ; buffer range face → void
 buffer-readonly-range!           ; buffer range flag → void
 buffer-face-cell!                ; buffer line col face → void
 buffer-readonly-cell!            ; buffer line col flag → void
 buffer-face-line!                ; buffer line face → void
 buffer-readonly-line!            ; buffer line flag → void
 buffer-face-batch!               ; buffer fills → void
 buffer-readonly-batch!           ; buffer fills → void
 buffer-face-range-batch!         ; buffer runs → void
 buffer-readonly-range-batch!     ; buffer runs → void

 ;; ---------- 槽 ----------
 buffer-slot-set!)                ; buffer slot value → void

(define (doc b) (buffer-document b))

;;; ---------- 通用：区间 / 格 / 行 → 写回 ----------

(define (doc-range! b fill-doc r val)
  (define r* (range-normalize r))
  (fill-doc (doc b)
            (point-line (range-start r*)) (point-column (range-start r*))
            (point-line (range-end r*))   (point-column (range-end r*))
            val)
  (void))

(define (doc-cell! b fill-doc line col val)
  (define len (track-line-length (document-text (doc b)) line))
  (unless (>= col len)
    (doc-range! b fill-doc (range-of (point line col) (point line (add1 col))) val)))

(define (doc-line! b fill-doc line val)
  (define len (track-line-length (document-text (doc b)) line))
  (doc-range! b fill-doc (range-of (point line 0) (point line len)) val))

;;; ---------- 端口 ----------

(define (buffer-set-face! b face) (document-set-face! (doc b) face) (void))
(define (buffer-set-readonly! b ro) (document-set-readonly! (doc b) ro) (void))

(define (buffer-face-batch! b fills) (document-face-fill-batch (doc b) fills) (void))
(define (buffer-readonly-batch! b fills) (document-readonly-fill-batch (doc b) fills) (void))
(define (buffer-face-range-batch! b runs) (document-face-fill-range-batch (doc b) runs) (void))
(define (buffer-readonly-range-batch! b runs) (document-readonly-fill-range-batch (doc b) runs) (void))

(define (buffer-face-range! b r face) (doc-range! b document-face-fill r face))
(define (buffer-readonly-range! b r flag) (doc-range! b document-readonly-fill r flag))
(define (buffer-face-cell! b line col face) (doc-cell! b document-face-fill line col face))
(define (buffer-readonly-cell! b line col flag) (doc-cell! b document-readonly-fill line col flag))
(define (buffer-face-line! b line face) (doc-line! b document-face-fill line face))
(define (buffer-readonly-line! b line flag) (doc-line! b document-readonly-fill line flag))

;;; ---------- 槽 ----------

(define (buffer-slot-set! b sl value) (document-slot-set! (doc b) sl value) (void))
