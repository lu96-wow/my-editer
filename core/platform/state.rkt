#lang racket

(require "../viewport/window.rkt" "../doc/document.rkt")

;;; platform/state.rkt —— editor 数据 + 查找
;;;
;;; 只给同目录的 write/neutral/reaction/program/command 用；**不进标准入口**。
;;; 这里只有数据与读取。
;;;
;;; 每个 document-entry 持有一个 **document**（纯文本 buffer ⊕ 标注 attrs）；
;;; view 看哪个文档由它的 `window.document` 决定。引用完整性（任一 view 的
;;; window.document 必是某个 document-entry 的 document）由 write.rkt 维持。

(provide
 (struct-out editor)
 (struct-out document-entry)
 (struct-out view)
 (struct-out change-report)
 view-document
 view-buffer
 document-id-of
 view-of-document
 editor-document-entry
 editor-view-ref
 editor-focused-view
 editor-history
 check-sync)

;;; ---------- 数据 ----------

(struct document-entry (id name document history) #:transparent)

;; 一次命令的影响（新坐标系）；命令返回 #f 表示什么都没发生。
;; texts : (listof edit-desc) —— **施加顺序**；每个 desc 的坐标是「施加它之前」的文档状态
;;         （可直接喂 edits-map-position，或转成 LSP 的增量 didChange）。
;; attrs : (listof attr-desc) —— 本次命令施加的属性变更（施加顺序）。
;; 受影响行区间是二者的投影，由读面现算（见 neutral.rkt）。
(struct change-report (texts attrs) #:transparent)

(struct view (id window sync) #:transparent)
;; window : window            本视图看的 document 在其内
;; sync   : 'free | 'follow   显示语义的策略槽，由 reaction 读取

(struct editor (documents views focus next-document next-view) #:transparent)
;; documents   : (listof document-entry)   顺序稳定
;; views     : (listof view)           顺序稳定
;; focus     : (or/c #f view-id)
;; next-*    : nat                     下一个可用 id

;;; ---------- 查找 ----------

;; view 看哪个文档：window 里的 document。
(define (view-document v) (window-document (view-window v)))
;; 便利：view 看的**文本**。
(define (view-buffer v) (document-buffer (view-document v)))

;; document 值 → 它在 registry 里的名字。引用完整性：找不到即错误
;; （每个 document 值恰属于一个 entry：document-open/编辑都产生新值）。
(define (document-id-of ed d)
  (define e (for/first ([e (in-list (editor-documents ed))]
                        #:when (eq? d (document-entry-document e)))
              e))
  (unless e (error 'document-id-of "这个 document 不在 editor 里：~a" d))
  (document-entry-id e))

;; 同文档的第一个 view（按 did 寻址时的默认 view）。
(define (view-of-document ed did)
  (define d (document-entry-document (editor-document-entry ed did)))
  (for/first ([v (in-list (editor-views ed))] #:when (eq? d (view-document v))) v))

(define (editor-document-entry ed did)
  (or (for/first ([e (in-list (editor-documents ed))] #:when (= did (document-entry-id e))) e)
      (error 'editor "没有这个 document id: ~a" did)))

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

(define (editor-history ed did) (document-entry-history (editor-document-entry ed did)))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "../doc/buffer.rkt")
  (define d (document-open "s"))
  (define ed (editor (list (document-entry 0 "s" d 'H))
                     (list (view 0 (window-open d 24 80) 'free)) 0 1 1))

  (check-equal? (document-entry-id (editor-document-entry ed 0)) 0)
  (check-equal? (view-id (editor-view-ref ed 0)) 0)
  (check-equal? (view-id (editor-focused-view ed)) 0)
  (check-eq? (view-document (editor-view-ref ed 0)) d)
  (check-eq? (view-buffer (editor-view-ref ed 0)) (document-buffer d))
  (check-equal? (document-id-of ed d) 0)

  (check-exn exn:fail? (lambda () (editor-document-entry ed 9)))
  (check-exn exn:fail? (lambda () (check-sync 'x 'bad)))
  (displayln "state.rkt: all tests passed"))
