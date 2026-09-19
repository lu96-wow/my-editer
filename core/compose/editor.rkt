#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "../text/edit.rkt"
         "../view/window.rkt" "../view/document.rkt" "../tool/history.rkt" rackunit)

;;; core/compose/editor.rkt —— 组合原语：把 document + 账本 + 活动视图接成命令
;;;
;;; 问题（旧形态）：document + history + 活动视图下标三样必须一起 thread，
;;; 却没有名字；调用方只能靠位置记住 (doc hist i) → (values doc hist fl ll)，
;;; 容易配对错、记错顺序、把「变更行」两个裸值传来传去。
;;;
;;; 解决：把三样装进一个命名状态 editor；命令统一返回
;;;     (values editor (or/c #f change-report))
;;; 调用方不需要再记参数/返回值顺序。
;;;
;;;   compose-edit  document-edit + 记账 + 报变更行
;;;   compose-undo  取账本 → 走 document 的 trusted 落回（光标回 pre-point）
;;;   compose-redo  取账本 → trusted 落回（无 pre-point）
;;;
;;; 封掉的接缝坑：编辑后收 edit-change 记账；撤销/重放必须走 trusted；
;;; 变更行用整组 desc 取 edits-span。多文件/布局/主题仍是使用方的事。

(provide
 (struct-out editor)
 (struct-out change-report)
 editor-open
 editor-of-document
 editor-set-active
 editor-window
 compose-edit
 compose-undo
 compose-redo)

;;; ---------- 状态 ----------

(struct editor (document history active) #:transparent)
;; document : document
;; history  : history
;; active   : nat      当前编辑的视图下标

;; 一次命令影响到的行区间（**新坐标系**）。#f（命令返回处）表示什么都没发生。
(struct change-report (first-line last-line) #:transparent)

(define (editor-open text [height 24] [width 80])
  (define-values (doc _u1) (document-add-view (document-open text) height width))
  (editor doc (make-history) 0))

(define (editor-of-document doc [active 0])
  (editor doc (make-history) active))

(define (editor-set-active s i)
  (struct-copy editor s [active i]))

;; 活动视图的 window（渲染/查询用）
(define (editor-window s)
  (document-window (editor-document s) (editor-active s)))

;;; ---------- 命令 ----------

;; 编辑：document-edit + 记账 + 报变更行。
(define (compose-edit s op)
  (define-values (doc* ch) (document-edit (editor-document s) (editor-active s) op))
  (cond
    [(not ch) (values s #f)]
    [else
     (define-values (f l) (edits-span (list (edit-change-desc ch))))
     (values (struct-copy editor s
               [document doc*]
               [history (history-record (editor-history s) ch)])
             (change-report f l))]))

;; 撤销：pop → trusted 落回（光标回 pre-point）→ 报变更行。
(define (compose-undo s)
  (define-values (st h*) (history-pop-undo (editor-history s)))
  (cond
    [(not st) (values s #f)]
    [else
     (define-values (f l) (edits-span (step-undo-descs st)))
     (define doc* (document-apply-descs-trusted (editor-document s) (editor-active s)
                                                (step-undo-descs st) (step-pre-point st)))
     (values (struct-copy editor s [document doc*] [history h*])
             (change-report f l))]))

;; 重做：pop → trusted 落回（光标由最后一条 desc 推导）→ 报变更行。
(define (compose-redo s)
  (define-values (st h*) (history-pop-redo (editor-history s)))
  (cond
    [(not st) (values s #f)]
    [else
     (define-values (f l) (edits-span (step-replay-descs st)))
     (define doc* (document-apply-descs-trusted (editor-document s) (editor-active s)
                                                (step-replay-descs st)))
     (values (struct-copy editor s [document doc*] [history h*])
             (change-report f l))]))

;;; ---------- 测试 ----------

(module+ test
  (define s0 (editor-open ""))

  ;; 连续单字符并成一步；粘贴（多字符）自成一步；report 报变更行
  (define-values (s1 r1) (compose-edit s0 (edit-insert-char #\a)))
  (define-values (s2 _u2) (compose-edit s1 (edit-insert-char #\b)))
  (define-values (s3 _u3) (compose-edit s2 (edit-insert-char #\c)))
  (check-equal? (document->string (editor-document s3)) "abc")
  (check-equal? (change-report-first-line r1) 0)
  (check-equal? (history-undo-depth (editor-history s3)) 1)
  (define-values (s4 r4) (compose-edit s3 (edit-insert "de")))
  (check-equal? (document->string (editor-document s4)) "abcde")
  (check-equal? (history-undo-depth (editor-history s4)) 2)
  (check-equal? r4 (change-report 0 0))

  ;; 多行插入 → report 跨行
  (define-values (m1 rm) (compose-edit s0 (edit-insert "X\nY\n")))
  (check-equal? (document->string (editor-document m1)) "X\nY\n")
  (check-equal? rm (change-report 0 2))

  ;; 撤销 / 重做：文本 + 光标 + report
  (define-values (u1 ur) (compose-undo s3))
  (check-equal? (document->string (editor-document u1)) "")
  (check-equal? (window-point (editor-window u1)) (point 0 0))
  (check-equal? ur (change-report 0 0))
  (define-values (r1b rr) (compose-redo u1))
  (check-equal? (document->string (editor-document r1b)) "abc")
  (check-equal? (window-point (editor-window r1b)) (point 0 3))
  (check-equal? rr (change-report 0 0))

  ;; 空栈 / no-op → report #f，editor 原样
  (define-values (e1 er1) (compose-undo s0))
  (check-eq? e1 s0)
  (check-false er1)
  (define-values (e2 er2) (compose-redo s0))
  (check-false er2)
  (define-values (e3 er3) (compose-edit s0 (edit-backspace)))   ; (0,0) backspace 无操作
  (check-eq? e3 s0)
  (check-false er3)

  ;; 被 read-only 拒 → 不记账、不变、report #f
  (define rs (editor-open "abc"))
  (define rs1 (editor-of-document
               (document-put-restrict (editor-document rs) 0 0 2 (restrict #t))))
  (define rs2 (struct-copy editor rs1
                [document (document-update-view (editor-document rs1) 0
                                                (lambda (w) (window-goto w 0 1)))]))
  (define-values (rs3 er4) (compose-edit rs2 (edit-insert-char #\X)))
  (check-equal? (document->string (editor-document rs3)) "abc")
  (check-false er4)
  (check-false (history-can-undo? (editor-history rs3)))

  (displayln "editor.rkt: all tests passed"))
