#lang racket

;;; core/compose/editor.rkt —— 组合层：简化 core 组合（不做任何编辑器假设）
;;;
;;; 只把 core 原子 + core/tool/history.rkt 账本接成三个**纯函数**：
;;;   compose-edit   编辑（document-edit + 记账 + 报变更行）
;;;   compose-undo   撤销（history-pop + document-apply-descs-trusted + 报变更行）
;;;   compose-redo   重做（同上）
;;;
;;; 封掉的接缝坑（次序固定，使用方不该重写）：
;;;   · 编辑后收 edit-change 记账（忘了记就没有撤销）
;;;   · 撤销/重放必须走 document-apply-descs-trusted（记录在案的编辑当年过了守卫）
;;;   · 报变更行用 edits-span 传整组 desc
;;;
;;; **不定义任何状态结构**：doc、hist、视图索引都由使用方持有、显式传入。
;;; 一个编辑器开几个文件、怎么布局（侧边栏/多窗/状态行）、颜色怎么配，
;;; 全是使用方自己拼（示范见 example.rkt）。

(require "../api.rkt" "../tool/history.rkt")

(provide compose-edit compose-undo compose-redo)

;;; ============ 编辑 / 撤销 / 重做 ============

;; 编辑：document-edit + 记账 + 报变更行。
;; -> (values document history first-line last-line)
;; 没发生（no-op / 被拒）→ hist 原样、变更行 #f #f。
(define (compose-edit doc hist i op)
  (define-values (doc* ch) (document-edit doc i op))
  (define-values (f l) (edits-span (if ch (list (edit-change-desc ch)) '())))
  (values doc* (if ch (history-record hist ch) hist) f l))

;; 撤销：pop → document-apply-descs-trusted（光标回 pre-point）→ 报变更行。
(define (compose-undo doc hist i)
  (define-values (st h*) (history-pop-undo hist))
  (cond
    [(not st) (values doc hist #f #f)]
    [else
     (define-values (f l) (edits-span (step-undo-descs st)))
     (values (document-apply-descs-trusted doc i (step-undo-descs st) (step-pre-point st))
             h*
             f l)]))

;; 重做：pop → document-apply-descs-trusted（光标推进到重放后）→ 报变更行。
(define (compose-redo doc hist i)
  (define-values (st h*) (history-pop-redo hist))
  (cond
    [(not st) (values doc hist #f #f)]
    [else
     (define-values (f l) (edits-span (step-replay-descs st)))
     (values (document-apply-descs-trusted doc i (step-replay-descs st))
             h*
             f l)]))

;;; ============ 测试 ============

(module+ test
  (require rackunit)

  ;; 单视图文档 + 空账本
  (define (fresh [text ""])
    (define-values (d _) (document-add-view (document-open text) 24 80))
    (values d (make-history)))

  (define-values (d0 h0) (fresh ""))

  ;; 编辑：连续单字符并成一步；粘贴（多字符）自成一步
  (define-values (d1 h1 f1 l1) (compose-edit d0 h0 0 (edit-insert-char #\a)))
  (define-values (d2 h2 _1 _2) (compose-edit d1 h1 0 (edit-insert-char #\b)))
  (define-values (d3 h3 _3 _4) (compose-edit d2 h2 0 (edit-insert-char #\c)))
  (check-equal? (document->string d3) "abc")
  (check-equal? (list f1 l1) (list 0 0))                ; 单字符插入 → 变更 [0,0]
  (check-equal? (history-undo-depth h3) 1)              ; 三个单字符并成一步
  (define-values (d4 h4 f4 l4) (compose-edit d3 h3 0 (edit-insert "de")))
  (check-equal? (document->string d4) "abcde")
  (check-equal? (list f4 l4) (list 0 0))
  (check-equal? (history-undo-depth h4) 2)              ; 粘贴多字符 → 新的一步

  ;; 多行插入 → 变更行区间跨行
  (define-values (dm _hm fm lm) (compose-edit d0 h0 0 (edit-insert "X\nY\n")))
  (check-equal? (document->string dm) "X\nY\n")
  (check-equal? (list fm lm) (list 0 2))

  ;; 撤销 / 重做（也报变更行；光标回 pre-point / 推进到重放后）
  (define-values (du hu uf ul) (compose-undo d3 h3 0))
  (check-equal? (document->string du) "")
  (check-equal? (window-point (document-window du 0)) (point 0 0))
  (check-equal? (list uf ul) (list 0 0))
  (define-values (dr hr rf rl) (compose-redo du hu 0))
  (check-equal? (document->string dr) "abc")
  (check-equal? (window-point (document-window dr 0)) (point 0 3))
  (check-equal? (list rf rl) (list 0 0))

  ;; 空栈撤销 / 重做 → 原样返回（不报错）
  (define-values (de he _ef _el) (compose-undo d0 h0 0))
  (check-equal? (document->string de) "")
  (check-eq? he h0)
  (define-values (dr0 hr0 _rf0 _rl0) (compose-redo d0 h0 0))
  (check-eq? dr0 d0)

  ;; no-op（被 read-only 拒）→ doc/hist 原样、变更行 #f #f
  (define-values (ro0 _) (document-add-view (document-open "abc") 24 80))
  (define ro-h (make-history))
  (define ro1 (document-put-restrict ro0 0 0 2 (restrict #t)))
  (define ro2 (document-update-view ro1 0 (lambda (w) (window-goto w 0 1))))
  (define-values (ro3 ro-h3 rf2 rl2) (compose-edit ro2 ro-h 0 (edit-insert-char #\X)))
  (check-equal? (document->string ro3) "abc")           ; 没改
  (check-eq? ro-h3 ro-h)                                ; 没记账
  (check-false rf2)
  (check-false rl2)

  (displayln "editor.rkt: all tests passed"))
