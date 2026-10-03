#lang racket

;;; lab/model/ops.rkt —— 每文档的 读 + 写 门面
;;;
;;; 读：文本 / 名字 / 文件路径（core 已持有文本属性撤销，lab 只多一个 path delta）。
;;; 写：编辑 / 导航 / 焦点 / 结构（包 core 的 editor-view-*!，**就地**改 box）。
;;;
;;; 命令层只调这里，不直接 require core。「几何类」操作依赖 session 存的屏幕尺寸，
;;; 由派发层在调用前用 session-apply-layout! 把尺寸落到各 view。

(require
 "session.rkt"
 "layout.rkt"
 "../protocol.rkt"
 "../../core/editor.rkt"
 "../../core/text/document.rkt"
 "../../core/text/base/point.rkt"
 "../../core/text/base/selection.rkt")

(provide
 ;; ---------- 读（文本 / 名字 / 路径） ----------
 document-text document-name document-path document-set-path
 ;; ---------- 焦点 ----------
 active-view-id view-document-id
 focus-neighbor! focus-cycle!
 ;; ---------- 鼠标（layout 命中 ⊕ command 焦点） ----------
 focus-pane! click! wheel!
 ;; ---------- 编辑 ----------
 view-insert! view-backspace! view-delete!
 view-paste! view-copy! view-cut!
 view-undo! view-redo! view-select-all!
 ;; ---------- 导航 / 视口 ----------
 view-move! view-scroll! view-page! view-goto!
 ;; ---------- 结构 ----------
 split-active-view! close-active-view!)

(define (ed s) (session-editor s))

;;; ---------- 读（文件门面） ----------

(define (entry s did) (editor-document-entry (session-editor s) did))

(define (document-text s did)
  (document->string (document-entry-document (entry s did))))

(define (document-name s did)
  (document-entry-name (entry s did)))

(define (document-path s did)
  (doc-meta-path (hash-ref (session-docs s) did)))

(define (document-set-path s did path)
  (struct-copy session s
    [docs (hash-set (session-docs s) did (doc-meta path))]))

;;; ---------- 焦点 ----------

;; 焦点若是 editor 叶子 → vid；否则 → #f。
(define (active-view-id s)
  (define a (session-active s))
  (and (exact-nonnegative-integer? a) a))

(define (view-document-id s vid) (editor-view-document-id (ed s) vid))

;; 按几何方向把焦点移到相邻 pane。方向 'left/'right/'up/'down。
(define (focus-neighbor! s dir)
  (define cur (session-active s))
  (define nxt (and cur (layout-neighbor (session-rects s) cur dir)))
  (if nxt (session-focus s nxt) s))

;; 循环切到下一个 pane（含两棵树）。
(define (focus-cycle! s)
  (define ids (layout-ids (session-layout s)))
  (cond
    [(null? ids) s]
    [else
     (define cur (session-active s))
     (define idx (or (for/first ([x (in-list ids)] [i (in-naturals)] #:when (equal? x cur)) i) -1))
     (session-focus s (list-ref ids (modulo (add1 idx) (length ids))))]))

;;; ---------- 鼠标：layout 命中 ⊕ command 焦点 ----------
;;; 耦合点就在这几个函数：layout 只回答「点落在哪个 pane」；
;;; 这里把 pane-id 变成焦点，并把屏幕坐标变成 view 里的光标点。

;; 只聚焦（右键 / 中键）：命中 pane 且不是状态栏。
(define (focus-pane! s row col)
  (define r (layout-hit (session-rects s) row col))
  (define id (and r (pane-rect-id r)))
  (cond [(and id (not (eq? id 'status))) (session-focus s id)]
        [else s]))

;; 左键 / 拖拽：命中 view pane → 聚焦 + 光标落到点击处（extend? = Shift 扩选）。
(define (click! s row col [extend? #f])
  (define r (layout-hit (session-rects s) row col))
  (define id (and r (pane-rect-id r)))
  (cond
    [(not (exact-nonnegative-integer? id)) s]          ; 空隙 / 状态栏
    [else
     (define s* (session-focus s id))
     (define e (session-editor s*))
     (define-values (line col*)
       (editor-view-screen-pos->point e id (- row (pane-rect-y r)) (- col (pane-rect-x r))))
     (cond
       [(not line) s*]                                 ; 点在文末之外：只聚焦
       [extend? (editor-view-set-selections! e id
                  (selections-extend (editor-view-selections e id)
                                     (lambda (_) (point line col*))))
                s*]
       [else (editor-view-set-point! e id (point line col*)) s*])]))

;; 滚轮：以鼠标所在 pane 为目标，聚焦并滚动。
(define (wheel! s dir row col)
  (define r (layout-hit (session-rects s) row col))
  (define id (and r (pane-rect-id r)))
  (cond
    [(not (exact-nonnegative-integer? id)) s]
    [else (view-scroll! (session-focus s id) id (if (eq? dir 'up) -3 3))]))

;;; ---------- 编辑（就地） ----------

(define (view-insert! s vid text) (editor-view-insert! (ed s) vid text) s)
(define (view-backspace! s vid) (editor-view-backspace! (ed s) vid) s)
(define (view-delete! s vid) (editor-view-delete! (ed s) vid) s)
(define (view-paste! s vid) (editor-view-paste! (ed s) vid) s)
(define (view-copy! s vid) (editor-view-copy! (ed s) vid) s)
(define (view-cut! s vid) (editor-view-cut! (ed s) vid) s)
(define (view-undo! s vid) (editor-view-undo! (ed s) vid) s)
(define (view-redo! s vid) (editor-view-redo! (ed s) vid) s)
(define (view-select-all! s vid) (editor-view-select-all! (ed s) vid) s)

;;; ---------- 导航 / 视口 ----------

(define (view-move! s vid dir [extend? #f])
  (define e (ed s))
  (case dir
    [(left)  (editor-view-left! e vid extend?)]
    [(right) (editor-view-right! e vid extend?)]
    [(up)    (editor-view-up! e vid extend?)]
    [(down)  (editor-view-down! e vid extend?)]
    [(home)  (editor-view-home! e vid extend?)]
    [(end)   (editor-view-end! e vid extend?)]
    [else (error 'view-move! "dir 必须是 left/right/up/down/home/end，得到 ~a" dir)])
  s)

(define (view-scroll! s vid delta)
  (editor-view-scroll! (ed s) vid delta)
  s)

;; 翻页：向上/向下滚一屏。
(define (view-page! s vid dir)
  (define h (editor-view-height (ed s) vid))
  (view-scroll! s vid (if (eq? dir 'up) (- h) h)))

(define (view-goto! s vid row col)
  (editor-view-goto! (ed s) vid (point row col))
  s)

;;; ---------- 结构 ----------

;; 在焦点视图处分屏出同一文档的新视图。dir = 'row（左右）| 'col（上下）。
(define (split-active-view! s [dir 'row])
  (define a (active-view-id s))
  (cond
    [(not a) s]
    [else
     (define did (editor-view-document-id (ed s) a))
     (define-values (s* _vid) (session-split-view s did dir a))
     s*]))

(define (close-active-view! s)
  (define a (active-view-id s))
  (if a (session-close-view s a) s))
