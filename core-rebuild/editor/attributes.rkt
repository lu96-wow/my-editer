#lang racket

(require "state.rkt" "version.rkt" "../text/document.rkt"
         "../text/base/range.rkt" "../text/base/point.rkt"
         "../text/base/line.rkt" "../text/base/track.rkt")

;;; editor/attributes.rkt —— did 版写回层：端口（固定轨 API）+ 槽（opaque 值 API）
;;;
;;; 端口（face / readonly）是 core 固定契约，名字固定、API 固定（轨语义：fill/batch/...）。
;;; 槽（slot）是 opaque 存储，只有值级读改写，收 slot 句柄。
;;; 写都是「就地改 box、O(1)、不记 history 步」。
;;;
;;; 本层按 **did** 寻址当前文档，解析成版本句柄后交给 editor/version.rkt 写回。
;;; 版本层（按 document 句柄、异步）见 editor/version.rkt。
;;; 作用选区的端口命令（editor-view-face! / -readonly! …）在 command.rkt。

(provide
 ;; ---------- 端口：did 版 ----------
 editor-document-set-face! editor-document-set-readonly!
 editor-document-face-range! editor-document-readonly-range!
 editor-document-face-cell! editor-document-readonly-cell!
 editor-document-face-line! editor-document-readonly-line!
 editor-document-face-batch! editor-document-readonly-batch!
 editor-document-face-range-batch! editor-document-readonly-range-batch!

 ;; ---------- 槽：opaque 值（did 版） ----------
 editor-document-slot-set!)

;;; ---------- 通用：区间 / 格 / 行 → 写回 ----------
;; fill-doc : document -> l0 c0 l1 c1 val -> any

(define (doc-range! ed did fill-doc r val)
  (define r* (range-normalize r))
  (fill-doc (editor-document-handle ed did)
            (point-line (range-start r*)) (point-column (range-start r*))
            (point-line (range-end r*))   (point-column (range-end r*))
            val)
  (void))

(define (doc-cell! ed did fill-doc line col val)
  (define len (track-line-length (document-text (editor-document-handle ed did)) line))
  (unless (>= col len)
    (doc-range! ed did fill-doc (range-of (point line col) (point line (add1 col))) val)))

(define (doc-line! ed did fill-doc line val)
  (define len (track-line-length (document-text (editor-document-handle ed did)) line))
  (doc-range! ed did fill-doc (range-of (point line 0) (point line len)) val))

;;; ---------- 端口：did 版（解析 did → 版本句柄后写回） ----------

(define (editor-document-set-face! ed did face)
  (editor-document-handle-set-face! (editor-document-handle ed did) face))
(define (editor-document-set-readonly! ed did ro)
  (editor-document-handle-set-readonly! (editor-document-handle ed did) ro))

(define (editor-document-face-batch! ed did fills)
  (editor-document-handle-face-batch! (editor-document-handle ed did) fills))
(define (editor-document-readonly-batch! ed did fills)
  (editor-document-handle-readonly-batch! (editor-document-handle ed did) fills))
(define (editor-document-face-range-batch! ed did runs)
  (editor-document-handle-face-range-batch! (editor-document-handle ed did) runs))
(define (editor-document-readonly-range-batch! ed did runs)
  (editor-document-handle-readonly-range-batch! (editor-document-handle ed did) runs))

(define (editor-document-face-range! ed did r face) (doc-range! ed did document-face-fill r face))
(define (editor-document-readonly-range! ed did r flag) (doc-range! ed did document-readonly-fill r flag))
(define (editor-document-face-cell! ed did line col face)
  (doc-cell! ed did document-face-fill line col face))
(define (editor-document-readonly-cell! ed did line col flag)
  (doc-cell! ed did document-readonly-fill line col flag))
(define (editor-document-face-line! ed did line face) (doc-line! ed did document-face-fill line face))
(define (editor-document-readonly-line! ed did line flag)
  (doc-line! ed did document-readonly-fill line flag))

;;; ---------- 槽：did 版 ----------

(define (editor-document-slot-set! ed did sl value)
  (editor-document-handle-slot-set! (editor-document-handle ed did) sl value))
