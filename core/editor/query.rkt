#lang racket

(require "state.rkt"
         "../text/document.rkt" "history.rkt"
         "../text/base/point.rkt" "../text/base/selection.rkt" "../text/base/range.rkt"
         "../text/base/track.rkt" "../text/base/width.rkt"
         "../view/base/viewport.rkt" "../view/base/layout.rkt")

;;; editor/query.rkt —— 读（按 vid / did 读 view / document）
;;;
;;; 让 app 只经 editor API 取「文本 / 名称 / 点 / 选区 / 屏幕坐标 / 视口状态 / 历史状态」，
;;; 不必自己拆 view / viewport / document。都是纯读，不改任何东西。
;;;
;;; **无焦点糖**：焦点由宿主持有。
;;; 命名（按**寻址键**，不按用途）：
;;;   `editor-view-* ed vid`            按 vid
;;;   `editor-document-* ed did`        按 did
;;;   `editor-document-handle-* doc`    按 document 句柄（异步写回，见 attributes.rkt）
;;;   计数是全局总数（不带 id）：`editor-document-count` / `editor-view-count`。

(provide
 ;; ---------- 文本 / 名称 ----------
 editor-view-string
 editor-view-document-name
 editor-document-name

 ;; ---------- 属性（高亮 / 只读，读） ----------
 editor-view-highlight-at
 editor-view-readonly-at?
 editor-view-highlight-row
 editor-view-readonly-row
 editor-view-highlight-range?
 editor-view-readonly-range?
 editor-view-editable?

 ;; ---------- 计数 / 身份 ----------
 editor-document-count editor-view-count
 editor-view-document-id
 editor-view-sync
 editor-view-link

 ;; ---------- 点 / 选区 ----------
 editor-view-point
 editor-view-point-line
 editor-view-point-col
 editor-view-primary
 editor-view-primary-index
 editor-view-primary-range
 editor-view-selections
 editor-view-selection-count

 ;; ---------- 坐标换算 ----------
 editor-view-point->screen-pos
 editor-view-screen-pos->point

 ;; ---------- 视口状态 ----------
 editor-view-mode
 editor-view-line-numbers?
 editor-view-top-line
 editor-view-top-seg
 editor-view-left-col
 editor-view-width
 editor-view-height
 editor-view-visible-range

 ;; ---------- 历史 ----------
 editor-view-can-undo?
 editor-view-can-redo?
 editor-view-depth
 editor-view-history-enabled?
 editor-document-can-undo?
 editor-document-can-redo?
 editor-document-depth
 editor-document-history-enabled?)

;;; ---------- 文本 / 名称 ----------

(define (editor-view-string ed vid)
  (document->string (editor-view-document ed vid)))

(define (editor-view-document-name ed vid)
  (document-entry-name (editor-document-entry ed (view-did (editor-view-ref ed vid)))))
(define (editor-document-name ed did)
  (document-entry-name (editor-document-entry ed did)))

;;; ---------- 属性（高亮 / 只读，读） ----------

;; 单格：face / #f；是否只读。
(define (editor-view-highlight-at ed vid line col)
  (document-highlight-at (editor-view-document ed vid) line col))
(define (editor-view-readonly-at? ed vid line col)
  (document-readonly-at? (editor-view-document ed vid) line col))

;; 整行：属性格向量（整轨 #f → 全默认向量）。
(define (editor-view-highlight-row ed vid line)
  (document-highlight-row (editor-view-document ed vid) line))
(define (editor-view-readonly-row ed vid line)
  (document-readonly-row (editor-view-document ed vid) line))

;; 区间内是否有非默认属性格。
(define (editor-view-highlight-range? ed vid l0 c0 l1 c1)
  (document-highlight-range? (editor-view-document ed vid) l0 c0 l1 c1))
(define (editor-view-readonly-range? ed vid l0 c0 l1 c1)
  (document-readonly-range? (editor-view-document ed vid) l0 c0 l1 c1))

;; 区间是否可写（不被只读挡住）。零宽区间看插入点的格（行尾除外）。
(define (editor-view-editable? ed vid l0 c0 l1 c1)
  (document-editable? (editor-view-document ed vid) l0 c0 l1 c1))

;;; ---------- 计数 / 身份 ----------

(define (editor-document-count ed) (length (editor-documents ed)))
(define (editor-view-count ed) (length (editor-views ed)))
(define (editor-view-document-id ed vid) (view-did (editor-view-ref ed vid)))
(define (editor-view-sync ed vid) (view-sync (editor-view-ref ed vid)))
(define (editor-view-link ed vid) (view-link (editor-view-ref ed vid)))

;;; ---------- 点 / 选区 ----------

(define (editor-view-selections ed vid) (view-selections (editor-view-ref ed vid)))
(define (editor-view-point ed vid)
  (selection-head (selections-primary (editor-view-selections ed vid))))
(define (editor-view-point-line ed vid) (point-line (editor-view-point ed vid)))
(define (editor-view-point-col ed vid) (point-col (editor-view-point ed vid)))
(define (editor-view-primary ed vid) (selections-primary (editor-view-selections ed vid)))
(define (editor-view-primary-range ed vid)
  (define-values (a b) (selection-range (editor-view-primary ed vid)))
  (range-of a b))
(define (editor-view-primary-index ed vid) (selections-primary-index (editor-view-selections ed vid)))
(define (editor-view-selection-count ed vid) (selections-count (editor-view-selections ed vid)))

;;; ---------- 屏幕坐标 ↔ 点（鼠标 / 投影用） ----------

(define (editor-view-point->screen-pos ed vid p)
  (viewport-point->screen-pos (document-text (editor-view-document ed vid))
                              (view-viewport (editor-view-ref ed vid)) p))

(define (editor-view-screen-pos->point ed vid row col)
  (viewport-screen-pos->point (document-text (editor-view-document ed vid))
                              (view-viewport (editor-view-ref ed vid)) row col))

;;; ---------- 视口状态 ----------

(define (editor-view-mode ed vid) (viewport-mode (view-viewport (editor-view-ref ed vid))))
(define (editor-view-line-numbers? ed vid) (viewport-line-numbers? (view-viewport (editor-view-ref ed vid))))
(define (editor-view-top-line ed vid) (viewport-top-line (view-viewport (editor-view-ref ed vid))))
(define (editor-view-top-seg ed vid) (viewport-top-seg (view-viewport (editor-view-ref ed vid))))
(define (editor-view-left-col ed vid) (viewport-left-col (view-viewport (editor-view-ref ed vid))))
(define (editor-view-width ed vid) (viewport-width (view-viewport (editor-view-ref ed vid))))
(define (editor-view-height ed vid) (viewport-height (view-viewport (editor-view-ref ed vid))))

;; 视口里**真实显示出来的**文档区间（半开 [start, end)）：
;;   start = 顶行第一个显示位置；end = 底行可见内容之后的第一个位置。
;; clip 按 left-col ⊕ 可见宽取；wrap 按折行段取；文末之后的空白行不算。
;; 视口完全在文末之后 / 空内容 → 零宽 range（首行首列）。
(define (editor-view-visible-range ed vid)
  (define t (document-text (editor-view-document ed vid)))
  (define n (track-length t))
  (define vrows (viewport-vrows t (view-viewport (editor-view-ref ed vid))))
  (define first (vector-ref vrows 0))
  (cond
    [(>= (vrow-line first) n) (range-of (point 0 0) (point 0 0))]
    [else
     ;; 底行：从下往上找第一条**真实存在**的文档行（跳过文末后的空白行）。
     (define last-i (for/last ([i (in-range (vector-length vrows))]
                               #:when (< (vrow-line (vector-ref vrows i)) n)) i))
     (define last (vector-ref vrows last-i))
     (define fl (vrow-line first))
     (define ll (vrow-line last))
     (range-of (point fl (display-col->index (track-ref t fl) (vrow-start-col first)))
               (point ll (display-col->index (track-ref t ll) (vrow-end-col last))))]))

;;; ---------- 历史 ----------

(define (editor-document-can-undo? ed did)
  (history-can-undo? (editor-document-history ed did)))
(define (editor-document-can-redo? ed did)
  (history-can-redo? (editor-document-history ed did)))
(define (editor-document-depth ed did)
  (history-depth (editor-document-history ed did)))
;; 同上，按 did（history 是文档级属性；无 view 的文档也能读）。
(define (editor-document-history-enabled? ed did)
  (history-enabled? (editor-document-history ed did)))

(define (editor-view-can-undo? ed vid)
  (editor-document-can-undo? ed (view-did (editor-view-ref ed vid))))
(define (editor-view-can-redo? ed vid)
  (editor-document-can-redo? ed (view-did (editor-view-ref ed vid))))
(define (editor-view-depth ed vid)
  (editor-document-depth ed (view-did (editor-view-ref ed vid))))
(define (editor-view-history-enabled? ed vid)
  (editor-document-history-enabled? ed (view-did (editor-view-ref ed vid))))
