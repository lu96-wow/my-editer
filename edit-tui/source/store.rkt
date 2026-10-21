#lang racket

;;; edit-tui/source/store.rkt —— 来源快照索引（纯值）
;;;
;;; 模型：
;;;   by-id    source-id -> snapshot（包含被 buffer 覆盖的 disk 备用快照）
;;;   by-path  规范化 path -> 当前权威 source-id
;;;
;;; 规则：
;;;   · 一个 path 同时只有一个当前权威；
;;;   · open buffer 优先 disk；
;;;   · disk 快照仍保留在 by-id 里，buffer 关闭后回退；
;;;   · virtual source 没有 path，只按 id 存在；
;;;   · 同一个 buffer id 改 path（save-as）会先摘掉旧 path 索引。
;;;
;;; 本模块不做 IO；磁盘读取 / editor resource 同步在 boot/source-sync。

(provide (struct-out source-store)
         source-store-empty
         source-store?
         source-store-ref
         source-store-ref-by-path
         source-store-path-id
         source-store-put-snapshot
         source-store-set-buffer
         source-store-set-disk
         source-store-set-virtual
         source-store-remove-source
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

(define (source-authority-buffer? s)
  (eq? (source-snapshot-authority s) 'buffer))

(define (source-authority-disk? s)
  (eq? (source-snapshot-authority s) 'disk))

;; 移除某 path 上的 buffer override（如果有）。
(define (remove-buffer-at-path store path)
  (define id (source-store-path-id store path))
  (cond
    [(not id) store]
    [else
     (define s (source-store-ref store id))
     (if (and s (source-authority-buffer? s))
         (source-store-remove-source store id)
         store)]))

;; 从固定 by-id / by-path 写回一个 snapshot。
(define (store-with-snapshot store snapshot)
  (source-store (hash-set (source-store-by-id store)
                          (source-snapshot-id snapshot)
                          snapshot)
                (source-store-by-path store)))

;; 通用写入。调用方通常用下面的 set-* 包装。
(define (source-store-put-snapshot store snapshot)
  (define id (source-snapshot-id snapshot))
  (define path (source-snapshot-path snapshot))
  (define authority (source-snapshot-authority snapshot))
  (unless (memq authority '(buffer disk virtual))
    (raise-argument-error 'source-store-put-snapshot
                          "(or/c 'buffer 'disk 'virtual)"
                          authority))
  (when (and (eq? authority 'disk) (not path))
    (raise-argument-error 'source-store-put-snapshot "disk snapshot with path" snapshot))

  ;; 同一个 buffer id 改 path（save-as）时，先清掉旧 path 索引 / 旧快照。
  (define old (source-store-ref store id))
  (define store0
    (cond
      [(and old (eq? authority 'buffer))
       (source-store-remove-source store id)]
      [else store]))

  ;; 新 path 上如果已有别的 buffer override，也先摘掉。
  (define store1
    (cond
      [(and path (eq? authority 'buffer))
       (remove-buffer-at-path store0 path)]
      [else store0]))

  (define store2 (store-with-snapshot store1 snapshot))
  (define by-path*
    (cond
      [(not path) (source-store-by-path store2)]
      [(eq? authority 'buffer)
       (hash-set (source-store-by-path store2) path id)]
      [(eq? authority 'disk)
       ;; disk 不覆盖已有 buffer；有 buffer 时只放 by-id 备用。
       (define cur-id (hash-ref (source-store-by-path store2) path #f))
       (define cur (and cur-id (source-store-ref store2 cur-id)))
       (if (and cur (source-authority-buffer? cur))
           (source-store-by-path store2)
           (hash-set (source-store-by-path store2) path id))]
      [else (source-store-by-path store2)]))
  (source-store (source-store-by-id store2) by-path*))

(define (source-store-set-buffer store id path text #:version [version #f])
  (source-store-put-snapshot store (buffer-source id path text #:version version)))

(define (source-store-set-disk store path text #:version [version #f])
  (source-store-put-snapshot store (disk-source path text #:version version)))

(define (source-store-set-virtual store id text #:version [version #f])
  (source-store-put-snapshot store (virtual-source id text #:version version)))

;; 移除一个 source；如果它是 path 的当前权威，尝试回退到 disk。
(define (source-store-remove-source store id)
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
          (define disk-id (disk-source-id-for-path path))
          (if (hash-has-key? by-id* disk-id)
              (hash-set (source-store-by-path store) path disk-id)
              (hash-remove (source-store-by-path store) path))]))
     (source-store by-id* by-path*)]))

;; buffer id 是 source-id 里 'buffer 的 value。
(define (source-store-remove-buffer store id)
  (source-store-remove-source store (source-id 'buffer id)))

;; 删除磁盘来源；open buffer 仍然保留。
(define (source-store-remove-disk store path)
  (define p (source-normalize-path path))
  (if p
      (source-store-remove-source store (disk-source-id-for-path p))
      store))

;; workspace 应该看到的“当前真相”：
;;   · by-path 里每个 path 的权威 snapshot；
;;   · 没有 path 的 buffer/virtual snapshot。
;; 被 buffer 覆盖的 disk 不在这里。
(define (source-store-authoritative-snapshots store)
  (define path-snaps
    (for/list ([(path id) (in-hash (source-store-by-path store))]
               #:do [(define s (source-store-ref store id))]
               #:when s)
      s))
  (define pathless
    (for/list ([(id s) (in-hash (source-store-by-id store))]
               #:unless (source-snapshot-path s)
               #:unless (source-authority-disk? s))
      s))
  (append path-snaps pathless))

(define (source-store-all-snapshots store)
  (hash-values (source-store-by-id store)))
