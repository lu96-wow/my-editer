#lang racket

;;; edit4/content/adapter.rkt —— 文本引擎适配层（唯一 require core/editor 的模块）
;;;
;;; 引擎是命令式的（有 id、有 box）：结构操作返回新 editor，命令式操作原地改 box，
;;; 渲染把 rectangle 交给引擎做增量 patch。其余模块只走本模块，不直接碰 core。
;;; 命名 adapter 是强调它是「内容层与底层引擎的边界」。

(provide
 blank-editor
 add-document-view! add-view! add-panel!
 close-view close-document
 render-layout
 ;; 编辑
 insert! backspace! delete! nav! select-all! copy! cut! paste! undo! redo!
 set-point! assign! scroll! ensure! screen->point point->screen
 ;; 读
 view-did view-document-name view-line view-col view-string view-selection-empty?
 view-id-list document-id-list document-view-list
 document-name document-string document-handle
 view-size view-left-column
 ;; 属性写回
 face-line! face-range! face-batch! document-face-at readonly-range!
 ;; core 渲染词汇
 rectangle piece piece? piece-row piece-column piece-text piece-attr
 pane screen run)

(require "../../core/editor.rkt"
         "../../core/text/document.rkt")

(define (blank-editor) (make-blank-editor))

;;; ---------- 结构 ----------

(define (add-document-view! ed text w h name)
  (editor-add-document-view ed text w h name))

(define (add-view! ed did w h)
  (editor-add-view ed did w h))

(define (add-panel! ed str w h name)
  (define-values (ed* did) (editor-add-document ed str name))
  (define-values (ed** vid) (editor-add-view ed* did w h))
  (values ed** did vid))

(define (close-view ed vid) (editor-close-view ed vid))
(define (close-document ed did) (editor-close-document ed did))

;;; ---------- 渲染 ----------

(define (set-layout! ed rects) (editor-set-layout! ed rects))

;; → (values screen render-pieces selection-pieces)
;; rects   : (listof rectangle)（deep 分层由调用方决定）
;; borders : (listof (list row col text face deep)) 装饰层
(define (render-layout ed rects active w h old [borders '()])
  (editor-set-layout! ed rects)
  (define decorations
    (for/list ([b (in-list borders)])
      (match-define (list row col text face deep) b)
      (pane 'window-border row col
            (screen (string-length text) 1 (vector (list (run 0 text face))) '() '())
            deep)))
  (editor-render-layout-patch ed old rects active w h decorations))

;;; ---------- 编辑 ----------

(define (insert! ed vid text) (editor-view-insert! ed vid text) (void))
(define (backspace! ed vid) (editor-view-backspace! ed vid) (void))
(define (delete! ed vid) (editor-view-delete! ed vid) (void))
(define (select-all! ed vid) (editor-view-select-all! ed vid) (void))
(define (copy! ed vid) (editor-view-copy! ed vid) (void))
(define (cut! ed vid) (editor-view-cut! ed vid) (void))
(define (paste! ed vid) (editor-view-paste! ed vid) (void))
(define (undo! ed vid) (editor-view-undo! ed vid) (void))
(define (redo! ed vid) (editor-view-redo! ed vid) (void))
(define (set-point! ed vid line col) (editor-view-set-point! ed vid (point line col)) (void))
(define (assign! ed vid text) (editor-view-assign! ed vid text) (void))
(define (scroll! ed vid delta) (editor-view-scroll! ed vid delta) (void))
(define (ensure! ed vid) (editor-view-ensure! ed vid) (void))

(define (screen->point ed vid row col)
  (define-values (line column) (editor-view-screen-position->point ed vid row col))
  (and line (cons line column)))

(define (point->screen ed vid line col)
  (define-values (row column) (editor-view-point->screen-position ed vid (point line col)))
  (and row (cons row column)))

(define (nav! ed vid dir extend?)
  (case dir
    [(left)  (editor-view-left! ed vid extend?)]
    [(right) (editor-view-right! ed vid extend?)]
    [(up)    (editor-view-up! ed vid extend?)]
    [(down)  (editor-view-down! ed vid extend?)]
    [(home)  (editor-view-home! ed vid extend?)]
    [(end)   (editor-view-end! ed vid extend?)]
    [else (error 'nav! "未知方向: ~a" dir)]))

;;; ---------- 属性写回 ----------

(define (face-line! ed did line face) (editor-document-face-line! ed did line face) (void))
(define (face-batch! ed did fills) (editor-document-face-batch! ed did fills) (void))
(define (face-range! ed did l0 c0 l1 c1 face)
  (editor-document-face-range! ed did (range-of (point l0 c0) (point l1 c1)) face) (void))
(define (document-face-at ed did line col) (editor-document-face-at ed did line col))
(define (readonly-range! ed did l0 c0 l1 c1 flag)
  (editor-document-readonly-range! ed did (range-of (point l0 c0) (point l1 c1)) flag))

;;; ---------- 读 ----------

(define (view-did ed vid) (editor-view-document-id ed vid))
(define (view-id-list ed) (editor-view-id-list ed))
(define (document-id-list ed) (editor-document-id-list ed))
(define (document-view-list ed did) (editor-document-view-list ed did))
(define (view-document-name ed vid) (editor-view-document-name ed vid))
(define (view-line ed vid) (editor-view-point-line ed vid))
(define (view-col ed vid) (editor-view-point-column ed vid))
(define (view-string ed vid) (editor-view-string ed vid))
(define (view-selection-empty? ed vid) (selection-empty? (editor-view-primary ed vid)))
(define (document-name ed did) (editor-document-name ed did))
(define (document-string ed did) (editor-document-string ed did))
(define (document-handle ed did) (editor-document-handle ed did))
(define (view-size ed vid) (cons (editor-view-width ed vid) (editor-view-height ed vid)))
(define (view-left-column ed vid) (editor-view-left-column ed vid))
