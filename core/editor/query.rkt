#lang racket

(require "state.rkt"
         "../text/document.rkt" "history.rkt"
         "../text/base/point.rkt" "../text/base/selection.rkt" "../text/base/range.rkt"
         "../text/base/track.rkt" "../text/base/line.rkt" "../text/base/width.rkt"
         "../view/base/viewport.rkt" "../view/base/layout.rkt")

;;; editor/query.rkt —— 读（按 vid / did 读 view / document）
;;;
;;; 取「文本 / 名称 / 点 / 选区 / 屏幕坐标 / 视口状态 / 历史状态」。都是纯读。
;;;
;;; 寻址：
;;;   `editor-view-* ed vid`            按 vid
;;;   `editor-document-* ed did`        按 did
;;;   `editor-document-handle-* doc`    按 document 句柄（异步写回，见 version.rkt）
;;;   全局（无 id）：`make-blank-editor` / `editor-open` / `editor-documents` / …

(provide
 ;; ---------- 文本 / 名称 ----------
 editor-view-string
 editor-document-string
 editor-document-range-text
 editor-view-range-text
 editor-view-document-name
 editor-document-name
 editor-document-char-at
 editor-view-char-at

 ;; ---------- 端口（读） ----------
 editor-document-face
 editor-document-readonly
 editor-document-face-at
 editor-document-readonly-at?
 editor-document-face-row
 editor-document-readonly-row
 editor-document-face-range?
 editor-document-readonly-range?
 editor-document-editable?
 editor-view-face
 editor-view-readonly
 editor-view-face-at
 editor-view-readonly-at?
 editor-view-face-row
 editor-view-readonly-row
 editor-view-face-range?
 editor-view-readonly-range?
 editor-view-editable?

 ;; ---------- 槽（读，opaque 值） ----------
 editor-document-slot-ref
 editor-view-slot-ref

 ;; ---------- 身份 ----------
 editor-document-id-list editor-view-id-list
 editor-document-view-list
 editor-view-document-id
 editor-view-id-of editor-document-id-of

 ;; ---------- 点 / 选区 ----------
 editor-view-point
 editor-view-point-line
 editor-view-point-column
 editor-view-primary
 editor-view-primary-index
 editor-view-primary-range
 editor-view-selections
 editor-view-selection-count

 ;; ---------- 坐标换算 ----------
 editor-view-point->screen-position
 editor-view-screen-position->point

 ;; ---------- 视口状态 ----------
 editor-view-mode
 editor-view-line-numbers?
 editor-view-top-line
 editor-view-top-segment
 editor-view-left-column
 editor-view-width
 editor-view-height
 editor-view-visible-range

 ;; ---------- 视口锚点 ----------
 editor-view-anchor
 editor-view-anchor-point

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

(define (editor-document-string ed did)
  (document->string (editor-document-handle ed did)))
(define (editor-view-string ed vid)
  (editor-document-string ed (view-did (editor-view-handle ed vid))))

(define (editor-document-name ed did)
  (document-entry-name (editor-document-entry ed did)))
(define (editor-view-document-name ed vid)
  (editor-document-name ed (view-did (editor-view-handle ed vid))))

;; 某位置的字符（越界 → #f）；行内 O(1)，不整篇取串。
(define (editor-document-char-at ed did line col)
  (define t (document-text (editor-document-handle ed did)))
  (and (exact-nonnegative-integer? line) (< line (track-length t))
       (let ([l (track-ref t line)])
         (and (exact-nonnegative-integer? col) (< col (line-length l))
              (line-ref l col)))))
(define (editor-view-char-at ed vid line col)
  (editor-document-char-at ed (view-did (editor-view-handle ed vid)) line col))

;; 区间文本（纯文本；属性不随复制走）。
(define (editor-document-range-text ed did r)
  (document-range-text (editor-document-handle ed did) r))
(define (editor-view-range-text ed vid r)
  (editor-document-range-text ed (view-did (editor-view-handle ed vid)) r))

;;; ---------- 读：端口 / 槽 ----------
;;; 端口 / 槽是文档级状态，真身按 did；vid 版取 did。

(define (editor-document-face ed did) (document-face (editor-document-handle ed did)))
(define (editor-document-readonly ed did) (document-readonly (editor-document-handle ed did)))
(define (editor-document-face-at ed did line col)
  (document-face-at (editor-document-handle ed did) line col))
(define (editor-document-readonly-at? ed did line col)
  (document-readonly-at? (editor-document-handle ed did) line col))
(define (editor-document-face-row ed did line)
  (document-face-row (editor-document-handle ed did) line))
(define (editor-document-readonly-row ed did line)
  (document-readonly-row (editor-document-handle ed did) line))
(define (editor-document-face-range? ed did l0 c0 l1 c1)
  (document-face-range? (editor-document-handle ed did) l0 c0 l1 c1))
(define (editor-document-readonly-range? ed did l0 c0 l1 c1)
  (document-readonly-range? (editor-document-handle ed did) l0 c0 l1 c1))
(define (editor-document-editable? ed did l0 c0 l1 c1)
  (document-editable? (editor-document-handle ed did) l0 c0 l1 c1))

(define (editor-document-slot-ref ed did sl)
  (document-slot-ref (editor-document-handle ed did) sl))

(define (editor-view-face ed vid)
  (editor-document-face ed (view-did (editor-view-handle ed vid))))
(define (editor-view-readonly ed vid)
  (editor-document-readonly ed (view-did (editor-view-handle ed vid))))
(define (editor-view-face-at ed vid line col)
  (editor-document-face-at ed (view-did (editor-view-handle ed vid)) line col))
(define (editor-view-readonly-at? ed vid line col)
  (editor-document-readonly-at? ed (view-did (editor-view-handle ed vid)) line col))
(define (editor-view-face-row ed vid line)
  (editor-document-face-row ed (view-did (editor-view-handle ed vid)) line))
(define (editor-view-readonly-row ed vid line)
  (editor-document-readonly-row ed (view-did (editor-view-handle ed vid)) line))
(define (editor-view-face-range? ed vid l0 c0 l1 c1)
  (editor-document-face-range? ed (view-did (editor-view-handle ed vid)) l0 c0 l1 c1))
(define (editor-view-readonly-range? ed vid l0 c0 l1 c1)
  (editor-document-readonly-range? ed (view-did (editor-view-handle ed vid)) l0 c0 l1 c1))
(define (editor-view-slot-ref ed vid sl)
  (editor-document-slot-ref ed (view-did (editor-view-handle ed vid)) sl))
(define (editor-view-editable? ed vid l0 c0 l1 c1)
  (editor-document-editable? ed (view-did (editor-view-handle ed vid)) l0 c0 l1 c1))

;;; ---------- 计数 / 身份 ----------

(define (editor-view-document-id ed vid) (view-did (editor-view-handle ed vid)))

;; 反查：值 -> id（值必须属于本 editor，否则报错）。
;; 与 editor-view-handle / editor-document-handle（id -> 值）互逆。
(define (editor-view-id-of ed v)
  (or (for/first ([x (in-list (editor-views ed))] #:when (eq? v x)) (view-id x))
      (error 'editor-view-id-of "这个 view 不在 editor 里")))

(define (editor-document-id-of ed d)
  (or (for/first ([e (in-list (editor-documents ed))]
                  #:when (eq? d (document-entry-document e)))
        (document-entry-id e))
      (error 'editor-document-id-of "这个 document 不在 editor 里")))

;; 枚举：给 id。
(define (editor-document-id-list ed)
  (for/list ([e (in-list (editor-documents ed))]) (document-entry-id e)))
(define (editor-view-id-list ed)
  (for/list ([v (in-list (editor-views ed))]) (view-id v)))
(define (editor-document-view-list ed did)
  (for/list ([v (in-list (editor-views ed))] #:when (= did (view-did v))) (view-id v)))

;;; ---------- 点 / 选区 ----------

(define (editor-view-selections ed vid) (view-selections (editor-view-handle ed vid)))
(define (editor-view-point ed vid)
  (selection-head (selections-primary (editor-view-selections ed vid))))
(define (editor-view-point-line ed vid) (point-line (editor-view-point ed vid)))
(define (editor-view-point-column ed vid) (point-column (editor-view-point ed vid)))
(define (editor-view-primary ed vid) (selections-primary (editor-view-selections ed vid)))
(define (editor-view-primary-range ed vid)
  (define-values (a b) (selection-range (editor-view-primary ed vid)))
  (range-of a b))
(define (editor-view-primary-index ed vid) (selections-primary-index (editor-view-selections ed vid)))
(define (editor-view-selection-count ed vid) (selections-count (editor-view-selections ed vid)))

;;; ---------- 屏幕坐标 ↔ 点（鼠标 / 投影用） ----------

(define (editor-view-point->screen-position ed vid p)
  (viewport-point->screen-position (document-text (editor-view-document ed vid))
                              (view-viewport (editor-view-handle ed vid)) p))

(define (editor-view-screen-position->point ed vid row col)
  (viewport-screen-position->point (document-text (editor-view-document ed vid))
                              (view-viewport (editor-view-handle ed vid)) row col))

;;; ---------- 视口状态 ----------

(define (editor-view-mode ed vid) (viewport-mode (view-viewport (editor-view-handle ed vid))))
(define (editor-view-line-numbers? ed vid) (viewport-line-numbers? (view-viewport (editor-view-handle ed vid))))
(define (editor-view-top-line ed vid) (viewport-top-line (view-viewport (editor-view-handle ed vid))))
(define (editor-view-top-segment ed vid) (viewport-top-segment (view-viewport (editor-view-handle ed vid))))
(define (editor-view-left-column ed vid) (viewport-left-column (view-viewport (editor-view-handle ed vid))))
(define (editor-view-width ed vid) (viewport-width (view-viewport (editor-view-handle ed vid))))
(define (editor-view-height ed vid) (viewport-height (view-viewport (editor-view-handle ed vid))))

;; 视口左上角锚点 (buffer 行, 显示列)。见 view/base/viewport.rkt。
(define (editor-view-anchor ed vid)
  (viewport-anchor (document-text (editor-view-document ed vid))
                   (view-viewport (editor-view-handle ed vid))))

;; 视口左上角锚点 (buffer 行, 行内字符列)，按显示宽折算。
(define (editor-view-anchor-point ed vid)
  (define t (document-text (editor-view-document ed vid)))
  (define-values (line dc) (viewport-anchor t (view-viewport (editor-view-handle ed vid))))
  (point line (display-column->index (track-ref t line) dc)))

;; 视口里**真实显示出来的**文档区间（半开 [start, end)）：
;;   start = 顶行第一个显示位置；end = 底行可见内容之后的第一个位置。
;; clip 按 left-column ⊕ 可见宽取；wrap 按折行段取；文末之后的空白行不算。
;; 视口完全在文末之后 / 空内容 → 零宽 range（首行首列）。
(define (editor-view-visible-range ed vid)
  (define t (document-text (editor-view-document ed vid)))
  (define n (track-length t))
  (define vrows (viewport-vrows t (view-viewport (editor-view-handle ed vid))))
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
     (range-of (point fl (display-column->index (track-ref t fl) (vrow-start-column first)))
               (point ll (display-column->index (track-ref t ll) (vrow-end-column last))))]))

;;; ---------- 历史 ----------

(define (editor-document-can-undo? ed did)
  (history-can-undo? (editor-document-history ed did)))
(define (editor-document-can-redo? ed did)
  (history-can-redo? (editor-document-history ed did)))
(define (editor-document-depth ed did)
  (history-depth (editor-document-history ed did)))
;; 按 did。
(define (editor-document-history-enabled? ed did)
  (history-enabled? (editor-document-history ed did)))

(define (editor-view-can-undo? ed vid)
  (editor-document-can-undo? ed (view-did (editor-view-handle ed vid))))
(define (editor-view-can-redo? ed vid)
  (editor-document-can-redo? ed (view-did (editor-view-handle ed vid))))
(define (editor-view-depth ed vid)
  (editor-document-depth ed (view-did (editor-view-handle ed vid))))
(define (editor-view-history-enabled? ed vid)
  (editor-document-history-enabled? ed (view-did (editor-view-handle ed vid))))
