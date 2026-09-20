#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt"
         "../view/window.rkt" "../view/view.rkt"
         "../tool/history.rkt" rackunit)

;;; core/compose/mechanism.rkt —— 机制层：editor 数据 + 不变量 + 无策略写原语
;;;
;;; 只给同目录的 editor/reaction/program/command 用；**不进标准入口**。
;;; 这里的东西能破坏不变量（比如只换 buffer 不换别的），所以必须藏起来。
;;;
;;;   · 数据结构：editor / buffer-entry / view / change-report
;;;   · 查找：editor-buffer-entry / editor-view-ref / editor-focused-view
;;;   · 写原语（无策略）：
;;;       editor-swap-buffer   换某 buffer 的 buffer 值（entries + 同 buffer view 的引用）
;;;       editor-apply-edit    内容变更唯一漏斗（= buffer-apply-edit + swap）
;;;       editor-update-buffer 装饰类写回（f : buffer → buffer）
;;;       editor-put-view      换一个 view 的 window
;;;       editor-put-history / editor-record-history
;;;
;;; 不变量：任一 view 的 (window-buffer v) 必 eq? 于其 buffer-id 对应 entry 的 buffer。

(provide
 (struct-out editor)
 (struct-out buffer-entry)
 (struct-out view)
 (struct-out change-report)
 editor-buffer-entry
 editor-view-ref
 editor-focused-view
 editor-history
 check-sync
 editor-swap-buffer
 editor-apply-edit
 editor-update-buffer
 editor-put-view
 editor-set-view-sync
 editor-set-view-buffer
 editor-put-history
 editor-record-history)

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

;; 把指定 vid 的 view 交给 f 变换（f : view → view）；别的 view 不动。
;; 所有按 vid 定位的视图写入都走它。
(define (map-view ed vid f)
  (editor-view-ref ed vid)                 ; 校验存在
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-id v) vid) (f v) v))]))

;;; ---------- 写原语（无策略） ----------

;; 换某 buffer 的 buffer 值：entries + 同 buffer view 的 window.buffer 一起换。
;; **不**动光标、不滚屏、不 ensure（即使文本变了，光标也不映射）。
(define (editor-swap-buffer ed bid b*)
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [buffer b*]) e))]
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-buffer-id v) bid)
                 (struct-copy view v
                   [window (struct-copy window (view-window v) [buffer b*])])
                 v))]))

;; 内容变更唯一漏斗：把 desc 施加到 bid 的 buffer，再换引用。
;; 返回 (values editor 生效desc/#f)。**不做**任何显示决策（不映射光标）。
(define (editor-apply-edit ed bid d [guard? #t])
  (define b0 (buffer-entry-buffer (editor-buffer-entry ed bid)))
  (define-values (b* d*) (if guard? (buffer-apply-edit b0 d) (buffer-apply-edit-trusted b0 d)))
  (if (not d*)
      (values ed #f)
      (values (editor-swap-buffer ed bid b*) d*)))

;; 装饰类写回：f : buffer → buffer（不改文本）。换 buffer 引用即可，光标无需动。
(define (editor-update-buffer ed bid f)
  (editor-swap-buffer ed bid (f (buffer-entry-buffer (editor-buffer-entry ed bid)))))

;; 换一个 view 的 window（夹紧视口）；不碰别的 view。
(define (editor-put-view ed vid w)
  (map-view ed vid (lambda (v) (struct-copy view v [window (window-clamp-view w)]))))

;; 视图结构变换（无策略；只动指定的 view）
(define (editor-set-view-sync ed vid sync)
  (check-sync 'editor-set-view-sync sync)
  (map-view ed vid (lambda (v) (struct-copy view v [sync sync]))))

;; 把某个 view 切到另一个 buffer（换属主；不触发任何同步）
(define (editor-set-view-buffer ed vid bid)
  (define b* (buffer-entry-buffer (editor-buffer-entry ed bid)))
  (map-view ed vid
            (lambda (v)
              (struct-copy view v
                [buffer-id bid]
                [window (window-clamp-view (window-set-buffer (view-window v) b*))]))))

(define (editor-record-history ed bid ch)
  (define entry (editor-buffer-entry ed bid))
  (define entry* (struct-copy buffer-entry entry
                  [history (history-record (buffer-entry-history entry) ch)]))
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) entry* e))]))

(define (editor-put-history ed bid h)
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [history h]) e))]))

;;; ---------- 测试：机制原语 ----------

(module+ test
  ;; swap-buffer 不动光标
  (define e0 (editor (list (buffer-entry 0 "s" (buffer-open "old") (make-history)))
                     (list (view 0 0 (window-open (buffer-open "old") 3 10) 'free))
                     0 1 1))
  (define e1 (editor-swap-buffer e0 0 (buffer-open "NEW")))
  (check-equal? (window-buffer (view-window (editor-view-ref e1 0)))
                (buffer-entry-buffer (editor-buffer-entry e1 0)))
  (check-equal? (window-point (view-window (editor-view-ref e1 0))) (point 0 0))

  ;; apply-desc：内容变、光标字面不动
  (define-values (e2 d2) (editor-apply-edit e0 0 (edit-desc (point 0 0) (point 0 0) "XY")))
  (check-equal? (buffer->string (buffer-entry-buffer (editor-buffer-entry e2 0))) "XYold")
  (check-equal? (window-point (view-window (editor-view-ref e2 0))) (point 0 0))
  (check-equal? d2 (edit-desc (point 0 0) (point 0 0) "XY"))

  (displayln "mechanism.rkt: all tests passed"))
