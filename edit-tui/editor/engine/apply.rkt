#lang racket

;;; edit-tui/editor/engine/apply.rkt —— view-action 解释
;;;
;;; engine 只认 editor/engine/action.rkt 的 view-action：
;;; insert / paste / backspace / delete / kill-line / nav / point / select /
;;; scroll / ensure / undo / redo。
;;;
;;; 这里调用 core/editor 的 view 操作；engine store / UI projection 不参与。

(require racket/match
         "../../../core/editor.rkt"
         "action.rkt"
         "store.rkt")

(provide engine-apply-view-action!)

(define (nav-fn dir)
  (case dir
    [(left) view-left!]
    [(right) view-right!]
    [(up) view-up!]
    [(down) view-down!]
    [(home) view-home!]
    [(end) view-end!]
    [else #f]))

;; nav data: dir | (list dir extend?)
(define (apply-nav! v data)
  (match data
    [(list dir extend?)
     (define f (nav-fn dir))
     (unless f (error 'engine-apply-view-action! "未知方向：~a" dir))
     (f v extend?)]
    [dir
     (define f (nav-fn dir))
     (unless f (error 'engine-apply-view-action! "未知方向：~a" dir))
     (f v)]))

;; 翻页：按当前 viewport 高度滚一屏。
(define (page-lines v)
  (max 1 (sub1 (view-height v))))

;; 整屏：光标跟着走一屏（像 vim / less），不是只滚视口
(define (apply-scroll! v which)
  (case which
    [(page-up)   (for ([i (in-range (page-lines v))]) (view-up! v))]
    [(page-down) (for ([i (in-range (page-lines v))]) (view-down! v))]
    [else (view-scroll! v which)]))

;; 删到行尾（vim 的 C-k）。已在行尾时删掉换行，拼下一行。
(define (kill-line! v)
  (define b (view-buffer v))
  (define l (view-point-line v))
  (define c (view-point-column v))
  (define cur (buffer-line b l))
  (define len (and cur (string-length cur)))
  (cond
    [(not len) '()]
    [(< c len)
     (buffer-replace-range! b (range (point l c) (point l len)) "")]
    [(buffer-line b (add1 l))
     (buffer-replace-range! b (range (point l c) (point (add1 l) 0)) "")]
    [else '()]))

;; 鼠标点落在文档空白处：view-screen-position->point 返回 #f，
;; 这时取最近的有效位置（点击在可见区上方 -> 起点，否则 -> 可见区末尾）。
(define (view-point-at-or-nearest v row col)
  (define-values (line c) (view-screen-position->point v row col))
  (cond
    [line (point line c)]
    [else
     ;; 行越界：先夹到最近的有效行（上方 -> 可见区起点，否则 -> 可见区末行），
     ;; 再用该行的屏幕位置重新映射列，列仍由 viewport 夹到行尾。
     (define r (view-visible-range v))
     (define target (if (< row 0) (range-start r) (range-end r)))
     (define target-line (point-line target))
     (define-values (sr _sc)
       (view-point->screen-position v (point target-line 0)))
     (cond
       [(not sr) target]
       [else
        (define-values (l c*) (view-screen-position->point v sr col))
        (if l (point l c*) target)])]))

;; → #f | '() | (listof change)
;;   #f      = 被拒绝（只读等）
;;   '()     = 成功但无文本变化
;;   changes = 本次提交的精确变更（当前坐标由 change.after 表示）
(define (engine-apply-view-action! e action)
  (define vid (view-action-view-id action))
  (define v (engine-view-object e vid))
  (unless v (error 'engine-apply-view-action! "view 不存在：~a" vid))
  (define b (view-buffer v))
  (case (view-action-kind action)
    [(insert)
     ;; action 里是原始 UTF-8 bytes；document 是字符串，这里解一次
     (buffer-edit! b v (op-type (bytes->string/utf-8 (view-action-data action))))]
    [(paste)
     (buffer-edit! b v (op-paste (bytes->string/utf-8 (view-action-data action))))]
    [(backspace)
     (buffer-edit! b v (op-backspace))]
    [(delete)
     (buffer-edit! b v (op-delete))]
    [(kill-line)
     (kill-line! v)]
    [(nav)
     (apply-nav! v (view-action-data action))
     '()]
    [(point)
     ;; data = (list row col) | (list row col extend?)
     ;; extend? = #t：鼠标拖选，保留 anchor，只把 head 移到新位置。
     (match-define (list r c extend?)
       (match (view-action-data action)
         [(list r c) (list r c #f)]
         [(list r c e) (list r c e)]))
     (define p (view-point-at-or-nearest v r c))
     (if extend?
         (view-set-selections! v
                               (selections-one
                                (selection (selection-anchor (view-primary v)) p)))
         (view-set-point! v p))
     '()]
    [(select)
     (view-set-selections! v (view-action-data action))
     '()]
    [(scroll)
     (apply-scroll! v (view-action-data action))
     '()]
    [(ensure)
     (view-ensure! v)
     '()]
    ;; undo/redo 恢复的是旧 document：face / document slot / 分析缓存随 document
    ;; 一起回来，不是一次新的文本提交，因此不产生 change，也不触发解析。
    [(undo) (buffer-undo! b) '()]
    [(redo) (buffer-redo! b) '()]
    [else (error 'engine-apply-view-action! "未知 view action：~a" action)]))
