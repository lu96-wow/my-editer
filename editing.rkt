#lang racket

;;; editing.rkt —— 编辑的组合：编辑 → 记账 → 撤销 / 重做（＋多视图同步 ＋增量范围）
;;;
;;; 要表达的两件事：
;;;   1. **"要不要撤销"不改变你用哪个入口**。一次编辑只调 `document-edit`，它顺路交回
;;;      这次编辑的完整材料（`edit-change`）：收下存进账本，或者丢掉，随你。反悔时把
;;;      账本里的 desc 交给**唯一**的落回入口——它同时负责「文本回位 + 光标回位 +
;;;      对齐 follow 视图」。
;;;   2. **"哪些行要重画"是操作的产物，不是 buffer 上的槽**。单次编辑传它的 desc、
;;;      整步撤销/重放传整组 desc，都交给 `edits-span`（空 → `#f`）。所以下面三个
;;;      操作都把范围一起返回；导航不改文本，也就没有范围。
;;;
;;; 必要 API（core/api.rkt ＋ 消费层 history.rkt）：
;;;   装配  document-open        make-window            document-add-view
;;;   编辑  document-edit        edit-char / edit-insert / edit-newline
;;;                              edit-backspace / edit-delete
;;;   记账  make-history         history-record         history-pop-undo / -redo
;;;         step-undo-descs      step-replay-descs      step-point
;;;   落回  document-apply-descs-trusted
;;;   增量  edits-span                                   （一串 desc → 行区间并集）
;;;   导航  window-goto                                     （只动视图，不进账本）
;;;   观察  document->string     document-window        window-point
;;;
;;; 编辑路径上 **buffer-* 一个都不出现**：动作是 `edit-*`，材料由 `document-edit` 给。

(require "core/api.rkt" "history.rkt" rackunit)

;;; ---------- 组装：一个 buffer，两个视图（视图 1 跟随视图 0）----------

(struct ed (doc active hist) #:transparent)

(define (open-editor text)
  (define-values (doc i) (document-add-view (document-open text) (make-window 6 40)))
  (define-values (doc* _) (document-add-view doc (make-window 6 40) #:sync 'follow))
  (ed doc* i (make-history)))

;;; ---------- 编辑：一次调用 = 新状态 + 材料 + 要重画的行 ----------
;;; 第三、四返回值是**闭区间**（新坐标系的行号）；`#f #f` = 这次什么都没发生
;;; （no-op，或碰了 read-only 被守卫拒绝）——此时记账与重画都跳过。

(define (edit a op)
  (define-values (doc* ch) (document-edit (ed-doc a) (ed-active a) op))
  (define-values (f l) (edits-span (if ch (list (edit-change-desc ch)) '())))
  (values (struct-copy ed a
            [doc doc*]
            [hist (if ch (history-record (ed-hist a) ch) (ed-hist a))])
          f l))

;;; ---------- 导航：只动视图，不动文本、不进账本、没有重画范围 ----------

(define (nav a win-fn)
  (struct-copy ed a
    [doc (document-update-view-synced (ed-doc a) (ed-active a) win-fn)]))

;;; ---------- 撤销 / 重做：同一个入口，差别只有"传不传光标" ----------
;;; 撤销：账本记得该步**之前**的光标，显式放回去（推导不出来，见 §12.5 R5）。
;;; 重做：不给光标——desc 的天然落点（最后一条 desc 之后）就是当时的落点。
;;; 要重画的行 = **该步全部 desc 的并集**（一步可以有多条：连续打字会并成一步）。

(define (undo a)
  (define-values (st h*) (history-pop-undo (ed-hist a)))
  (cond
    [(not st) (values a #f #f)]                     ; 空栈：原样返回，没有范围
    [else
     (define-values (f l) (edits-span (step-undo-descs st)))
     (values (struct-copy ed a
               [doc (document-apply-descs-trusted (ed-doc a) (ed-active a)
                                                  (step-undo-descs st) (step-point st))]
               [hist h*])
             f l)]))

(define (redo a)
  (define-values (st h*) (history-pop-redo (ed-hist a)))
  (cond
    [(not st) (values a #f #f)]
    [else
     (define-values (f l) (edits-span (step-replay-descs st)))
     (values (struct-copy ed a
               [doc (document-apply-descs-trusted (ed-doc a) (ed-active a)
                                                  (step-replay-descs st))]
               [hist h*])
             f l)]))

;;; ---------- 观察 ----------

(define (text a) (document->string (ed-doc a)))
(define (cursor a i) (window-point (document-window (ed-doc a) i)))

(define (show tag a f l)
  (displayln (format "~a 文本=~s 视图0光标=~a 视图1光标=~a 撤销=~a 重做=~a 要重画的行=~a"
                     tag (text a) (cursor a 0) (cursor a 1)
                     (history-undo-depth (ed-hist a)) (history-redo-depth (ed-hist a))
                     (if f (list f l) #f))))

;;; ---------- 走一遍 ----------

(module+ main
  (define a0 (open-editor "hi"))
  (show "初始    " a0 #f #f)
  (define-values (a1 f1 l1) (edit a0 (edit-insert "你")))     ; 插入字符串
  (show "插入    " a1 f1 l1)
  (define-values (a2 f2 l2) (edit a1 (edit-newline)))         ; 换行
  (show "换行    " a2 f2 l2)
  (define-values (a3 f3 l3) (edit a2 (edit-char #\!)))        ; 插一个字符
  (show "插字符  " a3 f3 l3)
  (define-values (a4 f4 l4) (edit a3 (edit-backspace)))       ; 退格
  (show "退格    " a4 f4 l4)
  (define-values (a5 f5 l5) (undo a4))
  (show "撤销 1 次" a5 f5 l5)
  (define-values (a6 f6 l6) (undo a5))
  (show "撤销 2 次" a6 f6 l6)
  (define-values (a7 f7 l7) (redo a6))
  (show "重做 1 次" a7 f7 l7)
  (show "移动光标后" (nav a7 (lambda (w) (window-goto w 1 0))) #f #f))

;;; ---------- 测试 ----------

(module+ test
  ;; 连续打字并成一步（合并规则见 history.rkt）；范围是这一步的并集
  (define-values (a1 _f _l) (edit (open-editor "") (edit-insert "a")))
  (define-values (a2 _f2 _l2) (edit a1 (edit-insert "b")))
  (check-equal? (history-undo-depth (ed-hist a2)) 1)

  ;; 撤销：文本 + 光标都回到该步之前；范围 = 该步全部 desc 的并集（行 0）
  (define-values (a3 f3 l3) (undo a2))
  (check-equal? (text a3) "")
  (check-equal? (cursor a3 0) (point 0 0))
  (check-equal? (list f3 l3) (list 0 0))

  ;; 重做：文本回来；光标由 desc 推导 = 该步之后
  (define-values (a4 f4 l4) (redo a3))
  (check-equal? (text a4) "ab")
  (check-equal? (cursor a4 0) (point 0 2))
  (check-equal? (list f4 l4) (list 0 0))

  ;; 一次编辑自动同步所有视图（'follow 视图盯着编辑视图）
  (check-equal? (cursor a4 1) (point 0 2))

  ;; 空栈：原样返回、没有范围
  (define e0 (open-editor ""))
  (define-values (u0 uf ul) (undo e0))
  (check-eq? u0 e0)
  (check-false uf)
  (check-false ul)

  ;; 单次编辑的范围：插一行文本 → 区间跨行；纯删除 → 只占起点一行
  (define-values (m1 mf1 ml1) (edit (open-editor "aa\nbb") (edit-insert "X\nY\n")))
  (check-equal? (list mf1 ml1) (list 0 2))
  (define-values (m2 mf2 ml2) (edit (open-editor "aa\nbb") (edit-delete)))
  (check-equal? (list mf2 ml2) (list 0 0))

  ;; 前向删除的撤销：光标与范围都只有账本知道（这条断言就是 §12.5 R5 的由来）
  (define b1 (nav (open-editor "abc") (lambda (w) (window-goto w 0 1))))
  (define-values (b2 _bf _bl) (edit b1 (edit-delete)))
  (check-equal? (text b2) "ac")
  (define-values (b3 bf3 bl3) (undo b2))
  (check-equal? (text b3) "abc")
  (check-equal? (cursor b3 0) (point 0 1))
  (check-equal? (cursor b3 0) (cursor b1 0))
  (check-equal? (list bf3 bl3) (list 0 0))

  ;; 导航不产生步骤、也没有范围
  (check-equal? (history-undo-depth
                 (ed-hist (nav a4 (lambda (w) (window-goto w 0 1)))))
                1)

  (displayln "editing.rkt: all tests passed"))