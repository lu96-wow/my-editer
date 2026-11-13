#lang racket

;;; edit-tui/host/source.rkt —— 来源权威索引同步（buffer > disk）
;;;
;;; source-store 决定同一个 path 上哪份文本是真：
;;;   · 打开中的 buffer > 磁盘；
;;;   · buffer 关闭后回退到已加载的 disk snapshot；
;;;   · buffer 保存后把 disk snapshot 更新为保存后的文本；
;;;   · buffer 仍在编辑时，disk snapshot 保留为备用。
;;;
;;; 这里只做 host 侧的 IO / 同步；source-store 本身是纯值。
;;; workspace 消费 source-store-authoritative-snapshots，而不是直接读 engine。

(require racket/file
         racket/path
         "../lang/source/api.rkt"
         "../editor/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/resource.rkt")

(provide source-sync!)

(define source-store-empty* source-store-empty)

(define (buffer-source-id did)
  (source-id 'buffer did))

(define (disk-source-id path)
  (disk-source-id-for-path path))

(define (same-snapshot? s path text version)
  (and s
       (equal? (source-snapshot-path s) path)
       (equal? (source-snapshot-version s) version)
       (equal? (source-snapshot-text s) text)))

(define (read-disk path)
  (with-handlers ([exn:fail? (λ (_) (values #f #f))])
    (if (file-exists? path)
        (values (file->string path)
                (file-or-directory-modify-seconds path))
        (values #f #f))))

(define (ensure-disk store path)
  (define id (disk-source-id path))
  (cond
    [(source-store-ref store id) store]
    [else
     (define-values (text version) (read-disk path))
     (if text
         (source-store-set-disk store path text #:version version)
         store)]))

(define (sync-disk-clean! store path text version)
  (define id (disk-source-id path))
  (define old (source-store-ref store id))
  (cond
    [(same-snapshot? old path text version) store]
    [else (source-store-set-disk store path text #:version version)]))

(define (sync-resource store ed r)
  (define did (resource-doc-id r))
  (define path (resource-path r))
  (define text (editor-doc-text ed did))
  (define version (editor-doc-version ed did))
  (cond
    [(not text) store]
    [else
     (define store1
       (if path (ensure-disk store path) store))
     (define bid (buffer-source-id did))
     (define old (source-store-ref store1 bid))
     (define store2
       (if (same-snapshot? old path text version)
           store1
           (source-store-set-buffer store1 did path text #:version version)))
     ;; 保存后 buffer 干净：磁盘快照与 buffer 同步。
     (cond
       [(and path (not (resource-dirty? r version)))
        (sync-disk-clean! store2 path text version)]
       [else store2])]))

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
  (define old (or (editor-sources ed) source-store-empty*))
  (define store1
    (for/fold ([store old])
              ([r (in-list (resources-list (state-resources state)))])
      (sync-resource store ed r)))
  (define store2 (drop-stale-buffers store1 (active-buffer-ids state)))
  (set-editor-sources! ed store2)
  store2)
