#lang racket

;;; source 层：buffer / disk / virtual 的统一来源模型。

(require rackunit
         "../source/api.rkt")

(define p (source-normalize-path "/tmp/edit-tui-source-a.rkt"))
(check-true (string? p))

;;; ════════════════ buffer / disk 优先级 ════════════════

(define s0
  (source-store-set-disk source-store-empty p "disk-v1" #:version 'd1))
(check-equal? (source-snapshot-text (source-store-ref-by-path s0 p)) "disk-v1")
(check-equal? (source-snapshot-authority (source-store-ref-by-path s0 p)) 'disk)

;; 打开 buffer 后，同一路径读到 buffer，而不是 disk。
(define s1 (source-store-set-buffer s0 'buf1 p "buffer-v1" #:version 'b1))
(check-equal? (source-snapshot-text (source-store-ref-by-path s1 p)) "buffer-v1")
(check-equal? (source-snapshot-authority (source-store-ref-by-path s1 p)) 'buffer)
(check-equal? (source-snapshot-text
               (source-store-ref s1 (source-id 'disk p)))
              "disk-v1")

;; disk 更新不能覆盖 open buffer，但 disk snapshot 要留在 by-id 里备用。
(define s2 (source-store-set-disk s1 p "disk-v2" #:version 'd2))
(check-equal? (source-snapshot-text (source-store-ref-by-path s2 p)) "buffer-v1")
(check-equal? (source-snapshot-text
               (source-store-ref s2 (source-id 'disk p)))
              "disk-v2")

;; 关闭 buffer 后回退到最新 disk。
(define s3 (source-store-remove-buffer s2 'buf1))
(check-equal? (source-snapshot-text (source-store-ref-by-path s3 p)) "disk-v2")
(check-equal? (source-snapshot-authority (source-store-ref-by-path s3 p)) 'disk)

;;; ════════════════ 删除 disk ════════════════

(define s4 (source-store-remove-disk s3 p))
(check-false (source-store-ref-by-path s4 p))

;;; ════════════════ virtual ════════════════

(define s5 (source-store-set-virtual s4 'scratch "hello" #:version 'v1))
(check-equal? (source-snapshot-text (source-store-ref s5 (source-id 'virtual 'scratch))) "hello")
(check-false (source-snapshot-path (source-store-ref s5 (source-id 'virtual 'scratch))))
(check-true
 (for/or ([s (in-list (source-store-authoritative-snapshots s5))])
   (equal? (source-snapshot-id s) (source-id 'virtual 'scratch))))

;;; ════════════════ 多个 buffer / path 唯一性 ════════════════

(define s6 (source-store-set-buffer s5 'buf2 p "buffer-v2" #:version 'b2))
;; 同一 path 的旧 buffer override 被替换；disk 已在 s4 删除。
(check-equal? (source-snapshot-text (source-store-ref-by-path s6 p)) "buffer-v2")
(check-false (source-store-ref s6 (source-id 'buffer 'buf1)))
(check-false (source-store-ref s6 (source-id 'disk p)))

;;; ════════════════ authoritative 视图 ════════════════

(define auth (source-store-authoritative-snapshots s6))
(check-equal? (length auth) 2) ; path buffer + virtual
(check-true (for/or ([s (in-list auth)])
              (equal? (source-snapshot-id s) (source-id 'buffer 'buf2))))
(check-true (for/or ([s (in-list auth)])
              (equal? (source-snapshot-id s) (source-id 'virtual 'scratch))))
;; 被 buffer 覆盖的 disk 不应出现在 authoritative 视图里。
(check-false (for/or ([s (in-list auth)])
               (equal? (source-snapshot-id s) (source-id 'disk p))))

;;; ════════════════ key ════════════════

(check-equal? (source-snapshot-cache-key (source-store-ref-by-path s6 p))
              (list (source-id 'buffer 'buf2) 'b2))

;;; ════════════════ 边界：同一 buffer 改 path（save-as） ════════════════

(define p2 (source-normalize-path "/tmp/edit-tui-source-b.rkt"))
(define m0 (source-store-set-disk source-store-empty p "old-disk" #:version 'od))
(define m1 (source-store-set-buffer m0 'buf p "buffer" #:version 'v1))
(define m2 (source-store-set-buffer m1 'buf p2 "buffer" #:version 'v1))
;; 旧 path 回退到旧 disk；新 path 指向 buffer。
(check-equal? (source-snapshot-authority (source-store-ref-by-path m2 p)) 'disk)
(check-equal? (source-snapshot-text (source-store-ref-by-path m2 p)) "old-disk")
(check-equal? (source-snapshot-authority (source-store-ref-by-path m2 p2)) 'buffer)
(check-equal? (source-snapshot-text (source-store-ref-by-path m2 p2)) "buffer")

;;; ════════════════ 边界：disk 必须有 path ════════════════

(check-exn exn:fail? (lambda () (disk-source #f "x")))
(check-exn exn:fail? (lambda () (source-store-set-disk source-store-empty #f "x")))
;; remove-disk 对 #f path 是 no-op，而不是返回 #f
(define m3 (source-store-remove-disk m2 #f))
(check-true (source-store? m3))

;;; ════════════════ 边界：无 path buffer / virtual 进入 authoritative ════════════════

(define m4 (source-store-set-buffer m3 'scratch #f "scratch" #:version 's1))
(define auth2 (source-store-authoritative-snapshots m4))
(check-true (for/or ([snap (in-list auth2)])
              (equal? (source-snapshot-id snap) (source-id 'buffer 'scratch))))
(check-false (source-store-ref-by-path m4 #f))

;; 无 path buffer 用 remove-buffer 移除。
(define m5 (source-store-remove-buffer m4 'scratch))
(check-false (source-store-ref m5 (source-id 'buffer 'scratch)))


;;; ════════════════ 边界：同一 path 两个 buffer ════════════════

(define n0 (source-store-set-buffer source-store-empty 'b1 p "one" #:version 'n1))
(define n1 (source-store-set-buffer n0 'b2 p "two" #:version 'n2))
(check-equal? (source-snapshot-text (source-store-ref-by-path n1 p)) "two")
(check-false (source-store-ref n1 (source-id 'buffer 'b1)))

(displayln "edit-tui-rebuild/test/source.rkt: ok")
