#lang racket

;;; 资源管理：打开 / 命令绑定 / dirty / 保存 / 退出 / 关闭 / prompt。
(require rackunit
         "../main.rkt")

(define (open! store #:name [name #f] #:path [path #f] #:text [text ""]
                     #:tables [tables '()] #:version [version 0])
  (let-values ([(s as)
                (if name
                    (resource-open store #:name name #:path path #:text text
                                   #:tables tables #:version version)
                    (resource-open store #:path path #:text text
                                   #:tables tables #:version version))])
    (values s as)))

(define (prompt-of s)
  (resource-prompt s))

;;; ---------- 打开 ----------
(define s0 resource-store-empty)
(define-values (s1 as1) (open! s0 #:name "scratch" #:text "hello"))
(check-equal? (map resource-action-kind as1) '(create-buffer create-view))
(check-equal? (resource-action-data (car as1)) '(1 "scratch" "hello"))
(check-equal? (resource-action-data (cadr as1)) '(1 1))
(check-equal? (resource-focus s1) 1)
(check-equal? (map resource-id (resource-list s1)) '(1))
(check-equal? (resource-view-ids s1 1) '(1))
(check-false (resource-path s1 1))
(check-false (resource-writable? s1 1))
(check-false (resource-dirty? s1 1))
(check-equal? (resource-version (resource-ref s1 1)) 0)
(check-equal? (resource-saved-version (resource-ref s1 1)) 0)

;; 打开时就绑定命令表
(define base (keys ['a 'cmd-a] ['x 's 'cmd-xs]))
(define-values (s2 as2) (open! resource-store-empty #:name "main.rkt" #:path "main.rkt"
                               #:text "code" #:tables (list base) #:version 'v1))
(check-equal? (map resource-action-kind as2) '(create-buffer create-view))
(check-true (resource-writable? s2 1))
(check-equal? (resource-path s2 1) "main.rkt")
(let-values ([(st v) (command-table-stack-lookup (resource-command-stack s2 1) '(a))])
  (check-equal? st 'command)
  (check-equal? v 'cmd-a))
(let-values ([(st v) (command-table-stack-lookup (resource-command-stack s2 1) '(x s))])
  (check-equal? st 'command)
  (check-equal? v 'cmd-xs))

;;; ---------- dirty ----------
(define s3 (resource-mark-edited s2 1 'v2))
(check-true (resource-dirty? s3 1))
(check-equal? (resource-version (resource-ref s3 1)) 'v2)
(check-equal? (resource-saved-version (resource-ref s3 1)) 'v1)

;;; ---------- 有 path 保存 ----------
(define-values (s4 as4) (resource-save s3 1))
(check-equal? (map resource-action-kind as4) '(write-file))
(check-equal? (resource-action-data (car as4)) '(1 "main.rkt"))
(define-values (s5 as5) (resource-save-done s4 1 'v2))
(check-false (resource-dirty? s5 1))
(check-equal? (resource-saved-version (resource-ref s5 1)) 'v2)

;;; ---------- 无 path 保存：先要路径 ----------
(define-values (s6 as6) (resource-save s1 1))
(check-equal? as6 '())
(define p6 (prompt-of s6))
(check-not-false p6)
(check-equal? (prompt-kind p6) 'save-path)
(check-equal? (prompt-resource-id p6) 1)
(define-values (s7 as7) (resource-submit s6 (prompt-id p6) "new.txt"))
(check-equal? (map resource-action-kind as7) '(write-file))
(check-equal? (resource-action-data (car as7)) '(1 "new.txt"))
(check-equal? (resource-path s7 1) "new.txt")
(check-true (resource-writable? s7 1))
(define-values (s8 as8) (resource-save-done s7 1 0))
(check-false (resource-dirty? s8 1))

;;; ---------- quit: clean ----------
(define-values (sq asq) (resource-request-quit s2))
(check-equal? (map resource-action-kind asq) '(quit))
(check-equal? (resource-action-data (car asq)) '())

;;; ---------- quit: dirty, skip ----------
(define-values (sq2 asq2) (resource-request-quit s3))
(check-equal? asq2 '())
(check-equal? (prompt-kind (prompt-of sq2)) 'confirm)
(define-values (sq3 asq3) (resource-submit sq2 (prompt-id (prompt-of sq2)) 'skip))
(check-equal? (map resource-action-kind asq3) '(quit))

;;; ---------- quit: dirty pathless, save -> save-path -> save-done -> quit ----------
(define s9 (resource-mark-edited s1 1 'v2))
(define-values (sq4 asq4) (resource-request-quit s9))
(check-equal? asq4 '())
(check-equal? (prompt-kind (prompt-of sq4)) 'confirm)
(define-values (sq5 asq5) (resource-submit sq4 (prompt-id (prompt-of sq4)) 'save))
(check-equal? asq5 '())                         ; 还没 path，先出 save-path
(check-equal? (prompt-kind (prompt-of sq5)) 'save-path)
(define-values (sq6 asq6) (resource-submit sq5 (prompt-id (prompt-of sq5)) "scratch.txt"))
(check-equal? (map resource-action-kind asq6) '(write-file))
(define-values (sq7 asq7) (resource-save-done sq6 1 'v2))
(check-equal? (map resource-action-kind asq7) '(quit))
(check-false (resource-pending sq7))

;;; ---------- close: clean ----------
(define-values (sc asc) (resource-request-close s2 1))
(check-equal? (map resource-action-kind asc) '(close-resource))
(check-equal? (resource-list sc) '())
(check-false (resource-focus sc))

;;; ---------- close: dirty, cancel ----------
(define-values (sc2 asc2) (resource-request-close s3 1))
(check-equal? asc2 '())
(check-equal? (prompt-kind (prompt-of sc2)) 'confirm)
(define sc3 (resource-cancel sc2 (prompt-id (prompt-of sc2))))
(check-equal? (map resource-id (resource-list sc3)) '(1))
(check-false (resource-pending sc3))

;;; ---------- 事件 ----------
(define-values (_s evs) (resource-drain-events s5))
(check-true (for/or ([e (in-list evs)]) (eq? (resource-event-kind e) 'saved)))
(check-equal? (resource-events _s) '())

(displayln "edit-tui-rebuild/test/resource.rkt: ok")
