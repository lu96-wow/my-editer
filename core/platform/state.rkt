#lang racket

(require "../viewport/window.rkt")

;;; platform/state.rkt —— editor 数据 + 查找
;;;
;;; 只给同目录的 write/neutral/reaction/program/command 用；**不进标准入口**。
;;; 这里只有数据与读取。
;;;
;;; **view 不另存 buffer-id**：一个 view 看哪个文档，唯一来源就是它的 `window.buffer`
;;; （Unix 的 fd 表只把名字映射到描述符，指向对象的指针在描述符里，不在表里）。
;;; `buffer-id` 是 registry 给文档起的名字，需要时用 `buffer-id-of` 从文档值反查。
;;; 引用完整性（view 的 window.buffer 必是某个 buffer-entry 的 buffer）由 write.rkt 维持。

(provide
 (struct-out editor)
 (struct-out buffer-entry)
 (struct-out view)
 (struct-out change-report)
 view-buffer
 buffer-id-of
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
;; 受影响行区间不存字段：它是 edits 的投影（edits-span），读时现算（见 neutral.rkt）。
(struct change-report (edits) #:transparent)

(struct view (id window sync) #:transparent)
;; window : window            含本视图看的 buffer（唯一来源，不另存 buffer-id）
;; sync   : 'free | 'follow   显示语义的策略槽，由 reaction 读取

(struct editor (buffers views focus next-buffer next-view) #:transparent)
;; buffers   : (listof buffer-entry)   顺序稳定
;; views     : (listof view)           顺序稳定
;; focus     : (or/c #f view-id)
;; next-*    : nat                     下一个可用 id

;;; ---------- 查找 ----------

;; view 看哪个文档：唯一来源是 window 里的 buffer。
(define (view-buffer v) (window-buffer (view-window v)))

;; 文档值 → 它在 registry 里的名字。引用完整性：找不到即错误
;; （每个 buffer 值恰属于一个 entry：buffer-open/编辑都产生新值）。
(define (buffer-id-of ed b)
  (define e (for/first ([e (in-list (editor-buffers ed))]
                        #:when (eq? b (buffer-entry-buffer e)))
              e))
  (unless e (error 'buffer-id-of "这个 buffer 不在 editor 里：~a" b))
  (buffer-entry-id e))

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
  (require rackunit "../doc/buffer.rkt")
  (define b (buffer-open "s"))
  (define ed (editor (list (buffer-entry 0 "s" b 'H))
                     (list (view 0 (window-open b 24 80) 'free)) 0 1 1))
  (check-equal? (buffer-entry-id (editor-buffer-entry ed 0)) 0)
  (check-equal? (view-id (editor-view-ref ed 0)) 0)
  (check-equal? (buffer-id-of ed b) 0)
  (check-equal? (view-buffer (editor-view-ref ed 0)) b)
  (check-equal? (view-id (editor-focused-view ed)) 0)
  (check-exn exn:fail? (lambda () (editor-buffer-entry ed 9)))
  (check-exn exn:fail? (lambda () (check-sync 'x 'bad)))
  (displayln "state.rkt: all tests passed"))
