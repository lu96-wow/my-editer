#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/change.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt" "../doc/batch.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt"
         "../unit/history.rkt"
         "state.rkt" rackunit)

;;; platform/write.rkt —— 无策略写原语
;;;
;;; 只给同目录的 neutral/reaction/program/command 用；**不进标准入口**。
;;; 这里的东西能破坏不变量（比如只换 document 不换别的），所以必须藏起来。
;;;
;;;   editor-swap-document   换某 entry 的 document 值（entries + 同文档 view 的引用）
;;;   editor-apply-change    变更唯一漏斗（= document-apply-change + swap）
;;;   editor-apply-edit      文本单条漏斗
;;;   editor-apply-edit-batch 文本批量漏斗
;;;   editor-put-view        换一个 view 的 window
;;;   editor-set-view-sync / editor-set-view-document  视图结构变换
;;;   editor-put-buffer-name
;;;   editor-put-history / editor-record-history
;;;
;;; 不变量（由本层维持）：任一 view 的 window.document 必是某个 buffer-entry 的 document。

(provide
 editor-swap-document
 editor-apply-change
 editor-apply-edit
 editor-apply-edit-batch
 editor-put-view
 editor-set-view-sync
 editor-set-view-document
 editor-put-history
 editor-put-buffer-name
 editor-record-history)

;;; ---------- 视图定位 ----------

;; 把指定 vid 的 view 交给 f 变换（f : view → view）；别的 view 不动。
(define (map-view ed vid f)
  (editor-view-ref ed vid)                 ; 校验存在
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))])
             (if (= (view-id v) vid) (f v) v))]))

;;; ---------- 写原语（无策略） ----------

;; 换某 entry 的 document 值：entries + 同文档 view 的 window.document 一起换。
;; **不**动光标、不滚屏、不 ensure（即使文本变了，光标也不映射）。
(define (editor-swap-document ed bid d*)
  (define d0 (buffer-entry-document (editor-buffer-entry ed bid)))
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [document d*]) e))]
    [views (for/list ([v (in-list (editor-views ed))])
             ;; 同属主 view = window 指向同一个 document 值的 view。
             (if (eq? d0 (view-document v))
                 (struct-copy view v
                   [window (struct-copy window (view-window v) [document d*])])
                 v))]))

;; 变更唯一漏斗：把 change 施加到 bid 的 document，再换引用。
;; 返回 (values editor change-result/#f)。**不做**任何显示决策（不映射光标）。
(define (editor-apply-change ed bid ch [guard? #t])
  (define d0 (buffer-entry-document (editor-buffer-entry ed bid)))
  (define-values (d* res) (if guard?
                              (document-apply-change d0 ch)
                              (document-apply-change-trusted d0 ch)))
  (if (not res)
      (values ed #f)
      (values (editor-swap-document ed bid d*) res)))

;; 文本单条漏斗（便利）：返回 (values editor 生效desc/#f)。
(define (editor-apply-edit ed bid d [guard? #t])
  (define-values (ed* res) (editor-apply-change ed bid (change/edits (list d)) guard?))
  (define ds (if res (change-result-applied-texts res) '()))
  (values ed* (and (pair? ds) (car ds))))

;; 文本批量漏斗：返回 (values editor 生效descs 逆)；施加顺序且平行。
(define (editor-apply-edit-batch ed bid descs [guard? #t])
  (define-values (ed* res) (editor-apply-change ed bid (change/edits descs) guard?))
  (if res
      (values ed* (change-result-applied-texts res) (change-result-text-inverses res))
      (values ed '() '())))

;; 换一个 view 的 window（夹紧视口）；不碰别的 view。
(define (editor-put-view ed vid w)
  (map-view ed vid (lambda (v) (struct-copy view v [window (window-clamp-view w)]))))

;; 视图结构变换（无策略；只动指定的 view）
(define (editor-set-view-sync ed vid sync)
  (check-sync 'editor-set-view-sync sync)
  (map-view ed vid (lambda (v) (struct-copy view v [sync sync]))))

;; 把某个 view 切到另一个文档（换属主；不触发任何同步）
(define (editor-set-view-document ed vid bid)
  (define d* (buffer-entry-document (editor-buffer-entry ed bid)))
  (map-view ed vid
            (lambda (v)
              (struct-copy view v
                [window (window-clamp-view (window-set-document (view-window v) d*))]))))

;;; ---------- 账本写回 ----------

;; replay / undo 都是 change 的序列（正序施加）。
(define (editor-record-history ed bid replay undo pre-point)
  (define entry (editor-buffer-entry ed bid))
  (define entry* (struct-copy buffer-entry entry
                  [history (history-record (buffer-entry-history entry) replay undo pre-point)]))
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) entry* e))]))

(define (editor-put-buffer-name ed bid name)
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [name name]) e))]))

(define (editor-put-history ed bid h)
  (struct-copy editor ed
    [buffers (for/list ([e (in-list (editor-buffers ed))])
               (if (= (buffer-entry-id e) bid) (struct-copy buffer-entry e [history h]) e))]))

;;; ---------- 测试：机制原语 ----------

(module+ test
  ;; swap-document 不动光标
  (define d-old (document-open "old"))
  (define e0 (editor (list (buffer-entry 0 "s" d-old (history-empty)))
                     (list (view 0 (window-open d-old 3 10) 'free))
                     0 1 1))
  (define e1 (editor-swap-document e0 0 (document-open "NEW")))
  (check-eq? (window-document (view-window (editor-view-ref e1 0)))
             (buffer-entry-document (editor-buffer-entry e1 0)))
  (check-equal? (window-point (view-window (editor-view-ref e1 0))) (point 0 0))

  ;; apply-desc：内容变、光标字面不动
  (define-values (e2 d2) (editor-apply-edit e0 0 (edit-desc (point 0 0) (point 0 0) "XY")))
  (check-equal? (document->string (buffer-entry-document (editor-buffer-entry e2 0))) "XYold")
  (check-equal? (window-point (view-window (editor-view-ref e2 0))) (point 0 0))
  (check-equal? d2 (edit-desc (point 0 0) (point 0 0) "XY"))

  (displayln "write.rkt: all tests passed"))
