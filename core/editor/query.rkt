#lang racket

;;; editor/query.rkt —— 读（直接在对象上读）
;;;
;;; 宿主持有 buffer / view 对象，读操作直接在对象上取。

(require "state.rkt" "history.rkt"
         "../text/document.rkt"
         "../text/base/point.rkt" "../text/base/range.rkt"
         "../text/base/selection.rkt" "../text/base/track.rkt"
         "../text/base/line.rkt" "../text/base/width.rkt"
         "../view/base/viewport.rkt" "../view/base/layout.rkt")

(provide
 ;; ---------- 文本 / 名称 ----------
 buffer-string                    ; buffer → 全文
 view-string                      ; view → 全文
 buffer-range-text                ; buffer range → 区间文本
 view-range-text                  ; view range → 区间文本
 buffer-char-at                   ; buffer line col → char | #f
 view-char-at                     ; view line col → char | #f
 buffer-line                      ; buffer line → string | #f（整行）
 view-line                        ; view line → string | #f（整行）

 ;; ---------- 端口 / 槽（读） ----------
 buffer-face                      ; buffer → face 轨
 buffer-readonly                  ; buffer → readonly 轨
 buffer-face-at                   ; buffer line col → face | #f
 buffer-readonly-at?              ; buffer line col → bool
 buffer-face-row                  ; buffer line → face 行向量
 buffer-readonly-row              ; buffer line → readonly 行向量
 buffer-slot-ref                  ; buffer slot → 值
 view-face-at                     ; view line col → face | #f
 view-readonly-at?                ; view line col → bool
 buffer-face-any?                 ; buffer l0 c0 l1 c1 → bool（区间内是否有非默认 face）
 buffer-readonly-any?             ; buffer l0 c0 l1 c1 → bool（区间内是否有只读格）
 buffer-editable?                 ; buffer l0 c0 l1 c1 → bool

 ;; ---------- 点 / 选区 ----------
 view-point                       ; view → 主光标 point
 view-point-line                  ; view → 主光标行
 view-point-column                ; view → 主光标列
 view-primary                     ; view → 主选区
 view-primary-range               ; view → 主选区 range
 view-selection-count             ; view → 选区数

 ;; ---------- 坐标换算 ----------
 view-cursor-screen-position      ; view → 主光标屏幕位置（view 内坐标）(values row col) | (values #f #f)
 view-point->screen-position      ; view point → (values row col) | (values #f #f)
 view-screen-position->point      ; view row col → (values line col) | (values #f #f)

 ;; ---------- 视口状态 ----------
 view-mode                        ; view → 'clip | 'wrap
 view-line-numbers?               ; view → bool
 view-top-line                    ; view → 顶部 buffer 行
 view-left-column                 ; view → 水平滚动列
 view-width                       ; view → 宽
 view-height                      ; view → 高
 view-anchor                      ; view → (values line display-col)
 view-anchor-point                ; view → 锚点 point
 view-visible-range               ; view → 可见文档区间

 ;; ---------- 历史 ----------
 buffer-can-undo?                 ; buffer → bool
 buffer-can-redo?                 ; buffer → bool
 buffer-depth                     ; buffer → 可撤销步数
 buffer-history-enabled?          ; buffer → bool
 buffer-undo-target               ; buffer → 撤销目标文本 string | #f
 buffer-redo-target               ; buffer → 重做目标文本 string | #f
 buffer-history-limit)            ; buffer → past 上限 nat

;;; ---------- 文本 / 名称 ----------

(define (buffer-string b) (document->string (buffer-document b)))
(define (view-string v) (buffer-string (view-buffer v)))

(define (buffer-range-text b r) (document-range-text (buffer-document b) r))
(define (view-range-text v r) (buffer-range-text (view-buffer v) r))

(define (buffer-char-at b line col)
  (define t (document-text (buffer-document b)))
  (and (exact-nonnegative-integer? line) (< line (track-length t))
       (let ([l (track-ref t line)])
         (and (exact-nonnegative-integer? col) (< col (line-length l)) (line-ref l col)))))
(define (view-char-at v line col) (buffer-char-at (view-buffer v) line col))

;; 整行文本；行号越界 → #f。
(define (buffer-line b line)
  (define t (document-text (buffer-document b)))
  (and (exact-nonnegative-integer? line) (< line (track-length t))
       (track-ref t line)))
(define (view-line v line) (buffer-line (view-buffer v) line))

;;; ---------- 端口 / 槽（读） ----------

(define (buffer-face b) (document-face (buffer-document b)))
(define (buffer-readonly b) (document-readonly (buffer-document b)))
(define (buffer-face-at b line col) (document-face-at (buffer-document b) line col))
(define (buffer-readonly-at? b line col) (document-readonly-at? (buffer-document b) line col))
(define (buffer-face-row b line) (document-face-row (buffer-document b) line))
(define (buffer-readonly-row b line) (document-readonly-row (buffer-document b) line))
(define (buffer-slot-ref b sl) (document-slot-ref (buffer-document b) sl))
(define (view-face-at v line col) (buffer-face-at (view-buffer v) line col))
(define (view-readonly-at? v line col) (buffer-readonly-at? (view-buffer v) line col))
;; 区间内是否有非默认 face / 只读格 / 可编辑。
(define (buffer-face-any? b l0 c0 l1 c1)
  (document-face-range? (buffer-document b) l0 c0 l1 c1))
(define (buffer-readonly-any? b l0 c0 l1 c1)
  (document-readonly-range? (buffer-document b) l0 c0 l1 c1))
(define (buffer-editable? b l0 c0 l1 c1)
  (document-editable? (buffer-document b) l0 c0 l1 c1))

;;; ---------- 点 / 选区 ----------

(define (view-point v) (selection-head (selections-primary (view-selections v))))
(define (view-point-line v) (point-line (view-point v)))
(define (view-point-column v) (point-column (view-point v)))
(define (view-primary v) (selections-primary (view-selections v)))
(define (view-primary-range v)
  (define-values (a b) (selection-range (view-primary v)))
  (range-of a b))
(define (view-selection-count v) (selections-count (view-selections v)))

;;; ---------- 坐标换算 ----------

(define (view-point->screen-position v p)
  (viewport-point->screen-position (document-text (view-document v)) (view-viewport v) p))

;; 主光标在**当前 view 内**的屏幕位置 (row, col)；不可见 → (values #f #f)。
;; 终端绝对位置 = (row + 该 view 的窗格行偏移, col + 列偏移)，偏移由宿主布局提供。
(define (view-cursor-screen-position v)
  (view-point->screen-position v (view-point v)))
(define (view-screen-position->point v row col)
  (viewport-screen-position->point (document-text (view-document v)) (view-viewport v) row col))

;;; ---------- 视口状态 ----------

(define (view-mode v) (viewport-mode (view-viewport v)))
(define (view-line-numbers? v) (viewport-line-numbers? (view-viewport v)))
(define (view-top-line v) (viewport-top-line (view-viewport v)))
(define (view-left-column v) (viewport-left-column (view-viewport v)))
(define (view-width v) (viewport-width (view-viewport v)))
(define (view-height v) (viewport-height (view-viewport v)))

(define (view-anchor v)
  (viewport-anchor (document-text (view-document v)) (view-viewport v)))
(define (view-anchor-point v)
  (define t (document-text (view-document v)))
  (define-values (line dc) (viewport-anchor t (view-viewport v)))
  (point line (display-column->index (track-ref t line) dc)))

(define (view-visible-range v)
  (define t (document-text (view-document v)))
  (define n (track-length t))
  (define vrows (viewport-vrows t (view-viewport v)))
  (define first (vector-ref vrows 0))
  (cond
    [(>= (vrow-line first) n) (range-of (point 0 0) (point 0 0))]
    [else
     (define last-i (for/last ([i (in-range (vector-length vrows))]
                               #:when (< (vrow-line (vector-ref vrows i)) n)) i))
     (define last (vector-ref vrows last-i))
     (define fl (vrow-line first))
     (define ll (vrow-line last))
     (range-of (point fl (display-column->index (track-ref t fl) (vrow-start-column first)))
               (point ll (display-column->index (track-ref t ll) (vrow-end-column last))))]))

;;; ---------- 历史 ----------

(define (buffer-can-undo? b) (history-can-undo? (buffer-history b)))
(define (buffer-can-redo? b) (history-can-redo? (buffer-history b)))
(define (buffer-depth b) (history-depth (buffer-history b)))
(define (buffer-history-enabled? b) (history-enabled? (buffer-history b)))
(define (buffer-history-limit b) (history-limit (buffer-history b)))
;; 撤销 / 重做目标的**文本预览**（不推进栈）；无 → #f。
(define (buffer-undo-target b)
  (define d (history-undo-target (buffer-history b)))
  (and d (document->string d)))
(define (buffer-redo-target b)
  (define d (history-redo-target (buffer-history b)))
  (and d (document->string d)))
