#lang racket

;;; platform/state.rkt —— editor 数据 + 不变量 + 查找
;;;
;;; 只给同目录的 write/neutral/reaction/program/command 用；**不进标准入口**。
;;; 这里只有数据与读取：不变量（任一 view 的 window.buffer 必 eq? 于其 buffer-id
;;; 对应 entry 的 buffer）由写原语（write.rkt）维持。

(provide
 (struct-out editor)
 (struct-out buffer-entry)
 (struct-out view)
 (struct-out change-report)
 editor-buffer-entry
 editor-view-ref
 editor-focused-view
 editor-history
 check-sync)

;;; ---------- 数据 ----------

(struct buffer-entry (id name buffer history) #:transparent)

;; 一次命令的影响（新坐标系）；命令返回 #f 表示什么都没发生。
;; edits : (listof edit-desc) —— **施加顺序**；每个 desc 的坐标是「施加它之前」的文档状态
;;         （可直接喂 edits-map-position，或转成 LSP 的增量 didChange）。
(struct change-report (first-line last-line edits) #:transparent)

(struct view (id buffer-id window sync) #:transparent)
;; sync : 'free | 'follow   —— 显示语义的策略槽，由 reaction 读取

(struct editor (buffers views focus next-buffer next-view) #:transparent)
;; buffers   : (listof buffer-entry)   顺序稳定
;; views     : (listof view)           顺序稳定
;; focus     : (or/c #f view-id)
;; next-*    : nat                     下一个可用 id

;;; ---------- 查找 ----------

(define (editor-buffer-entry ed bid)
  (or (for/first ([e (in-list (editor-buffers ed))] #:when (= bid (buffer-entry-id e))) e)
      (error 'editor "没有这个 buffer id: ~a" bid)))

(define (editor-view-ref ed vid)
  (or (for/first ([v (in-list (editor-views ed))] #:when (= vid (view-id v))) v)
      (error 'editor "没有这个 view id: ~a" vid)))

(define (check-sync who s)
  (unless (memq s '(free follow))
    (error who "sync 必须是 'free 或 'follow，得到 ~a" s)))

(define (editor-focused-view ed)
  (define f (editor-focus ed))
  (unless f (error 'editor "当前没有焦点视图"))
  (editor-view-ref ed f))

(define (editor-history ed bid) (buffer-entry-history (editor-buffer-entry ed bid)))

;;; ---------- 测试：查找 ----------

(module+ test
  (require rackunit)
  (define ed (editor (list (buffer-entry 0 "s" 'B0 'H))
                     (list (view 0 0 'W0 'free)) 0 1 1))
  (check-equal? (buffer-entry-id (editor-buffer-entry ed 0)) 0)
  (check-equal? (view-id (editor-view-ref ed 0)) 0)
  (check-equal? (view-id (editor-focused-view ed)) 0)
  (check-exn exn:fail? (lambda () (editor-buffer-entry ed 9)))
  (check-exn exn:fail? (lambda () (check-sync 'x 'bad)))
  (displayln "state.rkt: all tests passed"))
