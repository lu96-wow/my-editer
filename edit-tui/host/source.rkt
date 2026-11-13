#lang racket

;;; edit-tui/host/source.rkt —— 打开 buffer 的来源权威索引（buffer override）
;;;
;;; source-store 在这里只记录“打开中的 buffer”：
;;;   · 同一 path 有 buffer -> buffer 是权威；
;;;   · buffer 关闭 -> 移除 override，不在 source-store 里保留磁盘副本；
;;;   · 未打开 / 已关闭文件 -> 由语言层按需读磁盘。
;;;
;;; 这样避免 disk snapshot 在“不自动刷新”前提下变成陈旧缓存。
;;; source-store 本身仍是纯值；workspace 消费它的 authoritative snapshots。

(require "../lang/source/api.rkt"
         "../editor/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/resource.rkt")

(provide source-sync!)

(define (buffer-source-id did)
  (source-id 'buffer did))

(define (sync-resource store ed r)
  (define did (resource-doc-id r))
  (define path (resource-path r))
  (define version (editor-doc-version ed did))
  (define old (source-store-ref store (buffer-source-id did)))
  ;; 版本是 document 身份：path / version 都没变时文本必然没变。
  ;; 先比较这两个字段，避免每帧为每个打开文件 materialize 整篇字符串。
  (cond
    [(and old
          (equal? (source-snapshot-path old) path)
          (eq? (source-snapshot-version old) version))
     store]
    [else
     (define text (editor-doc-text ed did))
     (cond
       [(not text) store]
       [else (source-store-set-buffer store did path text #:version version)])]))

(define (active-buffer-ids state)
  (for/list ([r (in-list (resources-list (state-resources state)))])
    (resource-doc-id r)))

(define (drop-stale-buffers store active)
  (for/fold ([store store])
            ([s (in-list (source-store-all-snapshots store))])
    (define id (source-snapshot-id s))
    (cond
      [(not (eq? (source-snapshot-authority s) 'buffer)) store]
      [(member (source-id-value id) active) store]
      [else (source-store-remove-source store id)])))

;; → source-store'（同时写回 editor 实例）
(define (source-sync! ed state)
  (define old (or (editor-sources ed) source-store-empty))
  (define store1
    (for/fold ([store old])
              ([r (in-list (resources-list (state-resources state)))])
      (sync-resource store ed r)))
  (define store2 (drop-stale-buffers store1 (active-buffer-ids state)))
  (set-editor-sources! ed store2)
  store2)
