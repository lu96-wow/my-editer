#lang racket

;;; edit-tui/source/store.rkt —— 来源快照索引（纯值）
;;;
;;; 规则：
;;;   · 一个 path 同时只能有一个“当前快照”；
;;;   · open buffer 永远优先 disk；
;;;   · disk 快照仍然保留在 by-id 里，buffer 关闭后可以回退；
;;;   · virtual source 没有 path，只按 id 存在。
;;;
;;; 本模块不做 IO：读磁盘、把 editor resource 转成 snapshot 都在 boot/source-sync。

(provide (struct-out source-store)
         source-store-empty
         source-store?
         source-store-ref
         source-store-ref-by-path
         source-store-path-id
         source-store-put
         source-store-set-buffer
         source-store-set-disk
         source-store-set-virtual
         source-store-remove
         source-store-remove-buffer
         source-store-remove-disk
         source-store-authoritative-snapshots
         source-store-all-snapshots)

(require "model.rkt")

(struct source-store
  (by-id      ; source-id -> source-snapshot
   by-path)   ; 规范化 path -> 当前权威 source-id
  #:transparent)

(define source-store-empty (source-store (hash) (hash)))

(define (source-store-ref store id)
  (hash-ref (source-store-by-id store) id #f))

(define (source-store-path-id store path)
  (define p (source-normalize-path path))
  (and p (hash-ref (source-store-by-path store) p #f)))

(define (source-store-ref-by-path store path)
  (define id (source-store-path-id store path))
  (and id (source-store-ref store id)))

(define (snapshot-authority-buffer? s)
  (eq? (source-snapshot-authority s) 'buffer))

(define (snapshot-authority-disk? s)
  (eq? (source-snapshot-authority s) 'disk))

;; 移除同 path 的旧 buffer snapshot，保证一个 path 只有一个 buffer override。
(define (remove-buffer-at-path store path)
  (define id (source-store-path-id store path))
  (cond
    [(not id) store]
    [else
     (define old (source-store-ref store id))
     (if (and old (snapshot-authority-buffer? old))
         (source-store-remove store id)
         store)]))

;; 通用写入：按 authority 决定 by-path。
(define (source-store-put store snapshot)
  (define id (source-snapshot-id snapshot))
  (define path (source-snapshot-path snapshot))
  (define authority (source-snapshot-authority snapshot))
  (define store0
    (cond
      [(and path (eq? authority 'buffer))
       (remove-buffer-at-path store path)]
      [else store]))
  (define by-id* (hash-set (source-store-by-id store0) id snapshot))
  (define by-path*
    (cond
      [(not path) (source-store-by-path store0)]
      [(eq? authority 'buffer)
       (hash-set (source-store-by-path store0) path id)]
      [(eq? authority 'disk)
       ;; disk 不覆盖已有 buffer；有 buffer 时只放在 by-id 里备用。
       (define cur-id (hash-ref (source-store-by-path store0) path #f))
       (define cur (and cur-id (source-store-ref store0 cur-id)))
       (if (and cur (snapshot-authority-buffer? cur))
           (source-store-by-path store0)
           (hash-set (source-store-by-path store0) path id))]
      [else (source-store-by-path store0)]))
  (source-store by-id* by-path*))

(define (source-store-set-buffer store id path text #:version [version #f])
  (source-store-put store (buffer-source id path text #:version version)))

(define (source-store-set-disk store path text #:version [version #f])
  (source-store-put store (disk-source path text #:version version)))

(define (source-store-set-virtual store id text #:version [version #f])
  (source-store-put store (virtual-source id text #:version version)))

;; 移除一个 source；如果它是当前 path 的权威，尝试回退到 disk snapshot。
(define (source-store-remove store id)
  (define snapshot (source-store-ref store id))
  (cond
    [(not snapshot) store]
    [else
     (define by-id* (hash-remove (source-store-by-id store) id))
     (define path (source-snapshot-path snapshot))
     (define by-path*
       (cond
         [(or (not path)
              (not (equal? (hash-ref (source-store-by-path store) path #f) id)))
          (source-store-by-path store)]
         [else
          (define disk-id (source-id-for-path path))
          (if (hash-has-key? by-id* disk-id)
              (hash-set (source-store-by-path store) path disk-id)
              (hash-remove (source-store-by-path store) path))]))
     (source-store by-id* by-path*)]))

(define (source-store-remove-buffer store id)
  (source-store-remove store (source-id 'buffer id)))

;; 删除磁盘来源；open buffer 仍然保留。
(define (source-store-remove-disk store path)
  (define p (source-normalize-path path))
  (and p
       (source-store-remove store (source-id-for-path p))))

;; workspace 应该看到的“当前真相”：
;;   · by-path 里每个 path 的权威 snapshot；
;;   · 没有 path 的 buffer/virtual snapshot。
;; 被 buffer 覆盖的 disk snapshot 不在这里。
(define (source-store-authoritative-snapshots store)
  (define path-snaps
    (for/list ([(path id) (in-hash (source-store-by-path store))])
      (source-store-ref store id)))
  (define pathless
    (for/list ([(id s) (in-hash (source-store-by-id store))]
               #:unless (source-snapshot-path s))
      s))
  (append path-snaps pathless))

(define (source-store-all-snapshots store)
  (hash-values (source-store-by-id store)))
