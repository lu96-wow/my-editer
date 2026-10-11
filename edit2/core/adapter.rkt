#lang racket

;;; edit2/adapter.rkt —— core 边界（唯一 require core/editor 的模块）
;;;
;;; core 的命令式引擎（有 id、有 box）在这里被适配成会话可用的原语：
;;; 结构操作返回新 editor，命令式操作原地改 box，渲染把 placements 落成 rectangle 再 patch。
;;; 其余模块只走本模块，不直接碰 core。

(provide
 blank-editor
 add-document-view! add-view! add-panel!
 close-view close-document
 layout->rectangles set-layout! render-layout
 ;; 编辑原语
 insert! backspace! delete! nav! select-all! copy! cut! paste! undo! redo! set-point! assign!
 scroll! screen->point
 ;; 读
 view-did view-document-name view-line view-col view-string view-selection-empty?
 view-id-list document-id-list document-view-list
 document-name document-string document-handle
 view-size
 ;; 分区尺寸
 set-view-size!
 ;; 属性写回
 face-line!
 ;; 渲染 piece 词汇（core 重导）
 piece piece? piece-row piece-column piece-text piece-attr)

(require "../../core/editor.rkt"
         "../../core/text/document.rkt"
         "layout.rkt")

(define (blank-editor) (make-blank-editor))

;;; ---------- 结构 ----------

;; → (values ed did vid)
(define (add-document-view! ed text w h name)
  (editor-add-document-view ed text w h name))

;; → (values ed vid)
(define (add-view! ed did w h)
  (editor-add-view ed did w h))

;; 面板：文档 + 视图（只读内容由调用方重建）。→ (values ed did vid)
(define (add-panel! ed str w h name)
  (define-values (ed* did) (editor-add-document ed str name))
  (define-values (ed** vid) (editor-add-view ed* did w h))
  (values ed** did vid))

;; 关视图 / 关文档（关文档连带其视图）。
(define (close-view ed vid) (editor-close-view ed vid))
(define (close-document ed did) (editor-close-document ed did))

;;; ---------- 布局 / 渲染 ----------

;; placements → core rectangle。空窗口（vid = #f）不产出 rectangle（仍占位，可命中/聚焦）。
(define (layout->rectangles placements)
  (for/list ([p (in-list placements)] #:when (placement-vid p))
    (define r (placement-rect p))
    (rectangle (placement-vid p) (rect-x r) (rect-y r) (rect-w r) (rect-h r) (placement-z p))))

(define (set-layout! ed placements)
  (editor-set-layout! ed (layout->rectangles placements)))

(define (set-view-size! ed vid w h) (editor-view-set-size! ed vid w h))

;; → (values screen render-pieces selection-pieces)
(define (render-layout ed placements active w h old)
  (define rs (layout->rectangles placements))
  (editor-set-layout! ed rs)
  (editor-render-layout-patch ed old rs active w h))

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
(define (screen->point ed vid row col)
  (define-values (line column) (editor-view-screen-position->point ed vid row col))
  (and line (cons line column)))
(define (face-line! ed did line face) (editor-document-face-line! ed did line face) (void))

(define (nav! ed vid dir extend?)
  (case dir
    [(left)  (editor-view-left! ed vid extend?)]
    [(right) (editor-view-right! ed vid extend?)]
    [(up)    (editor-view-up! ed vid extend?)]
    [(down)  (editor-view-down! ed vid extend?)]
    [(home)  (editor-view-home! ed vid extend?)]
    [(end)   (editor-view-end! ed vid extend?)]
    [else (error 'nav! "未知方向: ~a" dir)]))

;;; ---------- 读 ----------

(define (view-did ed vid) (editor-view-document-id ed vid))
(define (view-id-list ed) (editor-view-id-list ed))
(define (document-id-list ed) (editor-document-id-list ed))
(define (document-view-list ed did) (editor-document-view-list ed did))
(define (view-document-name ed vid) (editor-view-document-name ed vid))
(define (view-line ed vid) (editor-view-point-line ed vid))
(define (view-col ed vid) (editor-view-point-column ed vid))
(define (view-string ed vid) (editor-view-string ed vid))
(define (view-selection-empty? ed vid)
  (selection-empty? (editor-view-primary ed vid)))
(define (document-name ed did) (editor-document-name ed did))
(define (document-string ed did) (editor-document-string ed did))
(define (document-handle ed did) (editor-document-handle ed did))
(define (view-size ed vid)
  (cons (editor-view-width ed vid) (editor-view-height ed vid)))
