#lang racket

;;; editing.rkt —— 编辑的组合：编辑 → 记账 → 撤销 / 重做（＋多视图自动同步）
;;;
;;; 要表达的只有一件事：**"要不要撤销"不改变你用哪个入口**。
;;; 一次编辑只调 `document-edit`，它顺路交回这次编辑的完整材料（`edit-change`）：
;;; 收下存进账本，或者丢掉，随你。反悔时把账本里的 desc 交给**唯一**的落回入口，
;;; 它同时负责「文本回位 + 光标回位 + 对齐 follow 视图」。
;;;
;;; 必要 API（core/api.rkt ＋ 消费层 history.rkt）：
;;;   装配  document-open        make-window            document-add-view
;;;   编辑  document-edit        edit-char / edit-insert / edit-newline
;;;                              edit-backspace / edit-delete
;;;   记账  make-history         history-record         history-pop-undo / -redo
;;;         step-undo-descs      step-replay-descs      step-point
;;;   落回  document-apply-descs-trusted
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

;;; ---------- 编辑：一次调用 = 新文档 + 材料 ----------
;;; `ch` 非 #f 才入账；#f = 这次什么都没发生（no-op，或碰了 read-only 被守卫拒绝）。

(define (edit a op)
  (define-values (doc* ch) (document-edit (ed-doc a) (ed-active a) op))
  (struct-copy ed a
    [doc doc*]
    [hist (if ch (history-record (ed-hist a) ch) (ed-hist a))]))

;;; ---------- 导航：只动视图，不动文本、不进账本 ----------

(define (nav a win-fn)
  (struct-copy ed a
    [doc (document-update-view-synced (ed-doc a) (ed-active a) win-fn)]))

;;; ---------- 撤销 / 重做：同一个入口，差别只有"传不传光标" ----------
;;; 撤销：账本记得该步**之前**的光标，显式放回去（推导不出来，见 §12.5 R5）。
;;; 重做：不给光标——desc 的天然落点（最后一条 desc 之后）就是当时的落点。

(define (undo a)
  (define-values (st h*) (history-pop-undo (ed-hist a)))
  (if st
      (struct-copy ed a
        [doc (document-apply-descs-trusted (ed-doc a) (ed-active a)
                                           (step-undo-descs st) (step-point st))]
        [hist h*])
      a))

(define (redo a)
  (define-values (st h*) (history-pop-redo (ed-hist a)))
  (if st
      (struct-copy ed a
        [doc (document-apply-descs-trusted (ed-doc a) (ed-active a)
                                           (step-replay-descs st))]
        [hist h*])
      a))

;;; ---------- 观察 ----------

(define (text a) (document->string (ed-doc a)))
(define (cursor a i) (window-point (document-window (ed-doc a) i)))

(define (show tag a)
  (displayln (format "~a 文本=~s 视图0光标=~a 视图1光标=~a 撤销=~a 重做=~a"
                     tag (text a) (cursor a 0) (cursor a 1)
                     (history-undo-depth (ed-hist a)) (history-redo-depth (ed-hist a)))))

;;; ---------- 走一遍 ----------

(module+ main
  (define a0 (open-editor "hi"))
  (show "初始    " a0)
  (define a1 (edit a0 (edit-insert "你")))     ; 插入字符串
  (define a2 (edit a1 (edit-newline)))         ; 换行
  (define a3 (edit a2 (edit-char #\!)))        ; 插一个字符
  (define a4 (edit a3 (edit-backspace)))       ; 退格
  (show "打字 4 次" a4)
  (define a5 (undo a4))
  (show "撤销 1 次" a5)
  (define a6 (undo a5))
  (show "撤销 2 次" a6)
  (define a7 (redo a6))
  (show "重做 1 次" a7)
  (define a8 (nav a7 (lambda (w) (window-goto w 1 0))))
  (show "移动光标后" a8))

;;; ---------- 测试 ----------

(module+ test
  ;; 连续打字并成一步（合并规则见 history.rkt）
  (define a1 (edit (edit (open-editor "") (edit-insert "a")) (edit-insert "b")))
  (check-equal? (history-undo-depth (ed-hist a1)) 1)

  ;; 撤销：文本 + 光标都回到该步之前
  (define a2 (undo a1))
  (check-equal? (text a2) "")
  (check-equal? (cursor a2 0) (point 0 0))

  ;; 重做：文本回来；光标由 desc 推导 = 该步之后
  (define a3 (redo a2))
  (check-equal? (text a3) "ab")
  (check-equal? (cursor a3 0) (point 0 2))

  ;; 一次编辑自动同步所有视图（'follow 视图盯着编辑视图）
  (check-equal? (cursor a3 1) (point 0 2))

  ;; 空栈：原样返回，不报错
  (define a0 (open-editor ""))
  (check-eq? (undo a0) a0)
  (check-eq? (redo a0) a0)

  ;; 前向删除的撤销：光标只有账本记得（这条断言就是 §12.5 R5 的由来）
  (define b1 (nav (open-editor "abc") (lambda (w) (window-goto w 0 1))))
  (define b2 (edit b1 (edit-delete)))
  (check-equal? (text b2) "ac")
  (define b3 (undo b2))
  (check-equal? (text b3) "abc")
  (check-equal? (cursor b3 0) (point 0 1))
  (check-equal? (cursor b3 0) (cursor b1 0))

  ;; 导航不产生步骤（账本深度不变）
  (check-equal? (history-undo-depth (ed-hist (nav a3 (lambda (w) (window-goto w 0 1))))) 1)

  (displayln "editing.rkt: all tests passed"))