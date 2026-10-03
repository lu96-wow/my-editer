#lang racket

(require "state.rkt" "../text/document.rkt"
         "../text/base/range.rkt" "../text/base/point.rkt"
         "../text/base/line.rkt" "../text/base/track.rkt")

;;; editor/attributes.rkt —— 属性覆盖层（高亮 / 只读）
;;;
;;; 属性存在 document 的 box 里，是**文档级**可变覆盖层。所有属性写都是
;;; 「就地改 box、O(1)、不记 history 步」。两种寻址：
;;;
;;;   editor-document-*          ed did   写**当前**文档（写时按 did 现取）
;;;   editor-document-handle-*   doc      写**抓取时那一个**文档值
;;;                                       （版本敏感；不可达时静默失效 —— 异步写回用）
;;;
;;; 作用**选区**的属性命令（editor-view-highlight! / -readonly! …）在 command.rkt：
;;; 它们是视图态命令，算完区间后调这里的 editor-document-*。
;;;
;;; 低层逃逸口（原子句柄 / 视图文档句柄）保留在底部：入口 editor.rkt 不导出这三者，
;;; 只供 core 内部与测试用（host 一律走 editor-document-* 的 did 寻址）。

(provide
 ;; ---------- did 版：文档级属性写（坐标 / 整轨） ----------
 editor-document-set-highlight! editor-document-set-readonly!
 editor-document-highlight-range! editor-document-readonly-range!
 editor-document-highlight-cell! editor-document-readonly-cell!
 editor-document-highlight-line! editor-document-readonly-line!
 editor-document-highlight-batch! editor-document-readonly-batch!
 editor-document-highlight-range-batch! editor-document-readonly-range-batch!

 ;; ---------- 句柄式写回（版本敏感；异步） ----------
 editor-document-handle-set-highlight!
 editor-document-handle-set-readonly!
 editor-document-handle-highlight-batch!
 editor-document-handle-readonly-batch!
 editor-document-handle-highlight-range-batch!
 editor-document-handle-readonly-range-batch!

 ;; ---------- 低层逃逸口 ----------
 editor-view-document-handle
 editor-view-highlight-atom
 editor-view-readonly-atom)

;;; ---------- 句柄式写回（版本敏感） ----------

(define (editor-document-handle-set-highlight! doc hl) (document-set-highlight! doc hl) (void))
(define (editor-document-handle-set-readonly! doc ro) (document-set-readonly! doc ro) (void))
(define (editor-document-handle-highlight-batch! doc fills)
  (document-highlight-fill-batch doc fills) (void))
(define (editor-document-handle-readonly-batch! doc fills)
  (document-readonly-fill-batch doc fills) (void))
(define (editor-document-handle-highlight-range-batch! doc runs)
  (document-highlight-fill-range-batch doc runs) (void))
(define (editor-document-handle-readonly-range-batch! doc runs)
  (document-readonly-fill-range-batch doc runs) (void))

;;; ---------- did 版：写当前文档 ----------

(define (editor-document-set-highlight! ed did hl)
  (editor-document-handle-set-highlight! (editor-document-handle ed did) hl))
(define (editor-document-set-readonly! ed did ro)
  (editor-document-handle-set-readonly! (editor-document-handle ed did) ro))

(define (editor-document-highlight-batch! ed did fills)
  (editor-document-handle-highlight-batch! (editor-document-handle ed did) fills))
(define (editor-document-readonly-batch! ed did fills)
  (editor-document-handle-readonly-batch! (editor-document-handle ed did) fills))
(define (editor-document-highlight-range-batch! ed did runs)
  (editor-document-handle-highlight-range-batch! (editor-document-handle ed did) runs))
(define (editor-document-readonly-range-batch! ed did runs)
  (editor-document-handle-readonly-range-batch! (editor-document-handle ed did) runs))

;; 显式区间：range 先归一，再折成坐标。
(define (editor-document-highlight-range! ed did r face)
  (define r* (range-normalize r))
  (document-highlight-fill (editor-document-handle ed did)
                           (point-line (range-start r*)) (point-column (range-start r*))
                           (point-line (range-end r*))   (point-column (range-end r*))
                           face)
  (void))
(define (editor-document-readonly-range! ed did r flag)
  (define r* (range-normalize r))
  (document-readonly-fill (editor-document-handle ed did)
                          (point-line (range-start r*)) (point-column (range-start r*))
                          (point-line (range-end r*))   (point-column (range-end r*))
                          flag)
  (void))

;; 格 / 行：由当前文本算出行长，再折成 range。
(define (editor-document-highlight-cell! ed did line col face)
  (define len (track-line-length (document-text (editor-document-handle ed did)) line))
  (unless (>= col len)
    (editor-document-highlight-range! ed did (range-of (point line col) (point line (add1 col))) face)))
(define (editor-document-readonly-cell! ed did line col flag)
  (define len (track-line-length (document-text (editor-document-handle ed did)) line))
  (unless (>= col len)
    (editor-document-readonly-range! ed did (range-of (point line col) (point line (add1 col))) flag)))
(define (editor-document-highlight-line! ed did line face)
  (define len (track-line-length (document-text (editor-document-handle ed did)) line))
  (editor-document-highlight-range! ed did (range-of (point line 0) (point line len)) face))
(define (editor-document-readonly-line! ed did line flag)
  (define len (track-line-length (document-text (editor-document-handle ed did)) line))
  (editor-document-readonly-range! ed did (range-of (point line 0) (point line len)) flag))

;;; ---------- 低层逃逸口 ----------

;; 取某视图当前文档的句柄（= 连同不可变文本 + 可变属性原子）。
;; 仅供内部 / 测试：host 用 editor-document-handle ed (editor-view-document-id ed vid)。
(define (editor-view-document-handle ed vid)
  (editor-view-document ed vid))

;; 取属性原子的 box 句柄（想直接 set-box! / 交给别的线程读时用）。
(define (editor-view-highlight-atom ed vid)
  (document-highlight-atom (editor-view-document ed vid)))
(define (editor-view-readonly-atom ed vid)
  (document-readonly-atom (editor-view-document ed vid)))
