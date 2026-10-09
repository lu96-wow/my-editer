#lang racket

(require "state.rkt" "../text/document.rkt")

;;; editor/version.rkt —— 版本层：按 **document 句柄** 写回（版本敏感；异步）
;;;
;;; 这一层不按 did/vid 寻址，而是写「抓取时那一个文档值」：
;;;   · 异步结果必须落到发起请求的那一版，而不是"当前文档"；
;;;   · 版本已不可达 / 已被替换时，写入的是那个旧 document 值（静默失效）。
;;;
;;; 公共面只暴露 editor-document-handle-* 写函数；原子 box 句柄（atom）是更低层的
;;; 逃逸口（直接 set-box! / 交给别的线程），不属公共面。
;;;
;;; did 版写回（按 did 现取句柄再调这里）在 editor/attributes.rkt。

(provide
 ;; ---------- 句柄式写回（版本敏感） ----------
 editor-document-handle-set-face!
 editor-document-handle-set-readonly!
 editor-document-handle-face-batch!
 editor-document-handle-readonly-batch!
 editor-document-handle-face-compose!
 editor-document-handle-face-range-batch!
 editor-document-handle-readonly-range-batch!
 editor-document-handle-slot-set!

 ;; ---------- 低层逃逸口（不属公共面） ----------
 editor-view-document-handle
 editor-document-face-atom editor-document-readonly-atom editor-document-slot-atom
 editor-view-face-atom editor-view-readonly-atom editor-view-slot-atom)

;;; ---------- 句柄式写回 ----------

(define (editor-document-handle-set-face! doc face) (document-set-face! doc face) (void))
(define (editor-document-handle-set-readonly! doc ro) (document-set-readonly! doc ro) (void))
(define (editor-document-handle-face-batch! doc fills)
  (document-face-fill-batch doc fills) (void))
;; 分层写回：fills 逐格与已有值用 combine 合成（前景叠背景时用）。
(define (editor-document-handle-face-compose! doc fills combine)
  (document-face-fill-batch* doc fills combine) (void))
(define (editor-document-handle-readonly-batch! doc fills)
  (document-readonly-fill-batch doc fills) (void))
(define (editor-document-handle-face-range-batch! doc runs)
  (document-face-fill-range-batch doc runs) (void))
(define (editor-document-handle-readonly-range-batch! doc runs)
  (document-readonly-fill-range-batch doc runs) (void))
(define (editor-document-handle-slot-set! doc sl value) (document-slot-set! doc sl value) (void))

;;; ---------- 低层逃逸口 ----------

;; 取某视图当前文档的句柄（不可变文本 + 端口 / 槽）。
(define (editor-view-document-handle ed vid)
  (editor-view-document ed vid))

;; 取原子 box 句柄（想直接 set-box! / 交给别的线程读时用）。did 版按当前文档现取。
(define (editor-document-face-atom ed did) (document-face-atom (editor-document-handle ed did)))
(define (editor-document-readonly-atom ed did)
  (document-readonly-atom (editor-document-handle ed did)))
(define (editor-document-slot-atom ed did sl) (document-slot-atom (editor-document-handle ed did) sl))
(define (editor-view-face-atom ed vid) (document-face-atom (editor-view-document ed vid)))
(define (editor-view-readonly-atom ed vid) (document-readonly-atom (editor-view-document ed vid)))
(define (editor-view-slot-atom ed vid sl) (document-slot-atom (editor-view-document ed vid) sl))
