#lang racket

;;; 资源管理：打开 / 命令绑定 / dirty / 保存 / 退出 / 关闭 / prompt。
(require rackunit
         "../config/keymap/buffer.rkt"
         "../main.rkt")

(define (open! store #:name [name #f] #:path [path #f] #:text [text ""]
                     #:key-table [key-table (buffer-key-table path text)]
                     #:version [version 0])
  (let-values ([(s as)
                (if name
                    (resource-open store #:name name #:path path #:text text
                                   #:key-table key-table #:version version)
                    (resource-open store #:path path #:text text
                                   #:key-table key-table #:version version))])
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
                               #:text "code" #:key-table base #:version 'v1))
(check-equal? (map resource-action-kind as2) '(create-buffer create-view))
(check-true (resource-writable? s2 1))
(check-equal? (resource-path s2 1) "main.rkt")
(let-values ([(st v) (command-table-stack-lookup (resource-command-stack s2 1) '(a))])
  (check-equal? st 'command)
  (check-equal? v 'cmd-a))
(let-values ([(st v) (command-table-stack-lookup (resource-command-stack s2 1) '(x s))])
  (check-equal? st 'command)
  (check-equal? v 'cmd-xs))

;; 两个 buffer 可以有不同键表（buffer-local）
(define other (keys ['b 'cmd-b]))
(define-values (s2b _as2b)
  (open! s2 #:name "other.txt" #:path "other.txt" #:text "x"
         #:key-table other #:version 'v2))
(let-values ([(st v) (command-table-stack-lookup (resource-command-stack s2b 2) '(b))])
  (check-equal? st 'command)
  (check-equal? v 'cmd-b))
(let-values ([(st _v) (command-table-stack-lookup (resource-command-stack s2b 2) '(a))])
  (check-equal? st 'unbound))
(let-values ([(st _v) (command-table-stack-lookup (resource-command-stack s2b 1) '(a))])
  (check-equal? st 'command))

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

;;; ---------- 确认提示：带路径 + y/n/all/nall ----------
;; 两个 dirty 资源：y -> 存第一个；all -> 存剩下全部
(define-values (two0 two0as)
  (resource-open resource-store-empty #:name "a" #:path "a.txt"
                 #:text "A" #:key-table (buffer-key-table "a.txt" "A")
                 #:version 'va))
(define-values (two1 two1as)
  (resource-open two0 #:name "b" #:path "b.txt" #:text "B"
                 #:key-table (buffer-key-table "b.txt" "B")
                 #:version 'vb))
(void two0as) (void two1as)
(define two2 (resource-mark-edited (resource-mark-edited two1 1 'va2) 2 'vb2))
(define-values (tq tq0) (resource-request-quit two2))
(check-equal? tq0 '())
(check-equal? (prompt-kind (prompt-of tq)) 'confirm)
;; 提示里有文件路径
(check-true (string-contains? (prompt-label (prompt-of tq)) "a.txt"))
(define tpid1 (prompt-id (prompt-of tq)))
;; y -> 保存第一个；然后出现第二个 confirm，提示换成 b.txt
(define-values (tq1 tqa1 tqok1?) (resource-submit-text tq tpid1 "y"))
(check-true tqok1?)
(check-equal? (map resource-action-kind tqa1) '(write-file))
(check-equal? (resource-action-data (car tqa1)) '(1 "a.txt"))
(define-values (tq2 tqa2) (resource-save-done tq1 1 'va2))
(check-equal? tqa2 '())
(check-equal? (prompt-kind (prompt-of tq2)) 'confirm)
(check-true (string-contains? (prompt-label (prompt-of tq2)) "b.txt"))
;; ALL（大写）-> 保存剩下全部，然后 quit
(define tpid2 (prompt-id (prompt-of tq2)))
(define-values (tq3 tqa3 tqok2?) (resource-submit-text tq2 tpid2 "ALL"))
(check-true tqok2?)
(check-equal? (map resource-action-kind tqa3) '(write-file))
(check-equal? (resource-action-data (car tqa3)) '(2 "b.txt"))
(define-values (tq4 tqa4) (resource-save-done tq3 2 'vb2))
(check-equal? (map resource-action-kind tqa4) '(quit))

;; NALL -> 跳过全部，直接 quit
(define-values (nq nq0) (resource-request-quit two2))
(define npid (prompt-id (prompt-of nq)))
(define-values (nq1 nqa1 nqok?) (resource-submit-text nq npid "nall"))
(check-true nqok?)
(check-equal? (map resource-action-kind nqa1) '(quit))

;; 非法答案仍然拒绝
(define-values (bq bqa bok?) (resource-submit-text nq npid "maybe"))
(check-false bok?)

;;; ---------- 输入栏文本提交（Enter 接的 API） ----------
;; save-path：空白 -> 不合法；合法 -> 去空白后写文件
(define st1 (resource-mark-edited s1 1 'v2))        ; pathless + dirty
(define-values (sp1 asp1) (resource-save st1 1))
(check-equal? asp1 '())
(check-equal? (prompt-kind (prompt-of sp1)) 'save-path)
(define spid (prompt-id (prompt-of sp1)))
(define-values (sp2 asp2 ok1?) (resource-submit-text sp1 spid "   "))
(check-false ok1?)
(check-equal? asp2 '())
(check-equal? sp2 sp1)
(define-values (sp3 asp3 ok2?) (resource-submit-text sp1 spid "  scratch2.txt  "))
(check-true ok2?)
(check-equal? (map resource-action-kind asp3) '(write-file))
(check-equal? (resource-path sp3 1) "scratch2.txt")

;; confirm：非法值 -> ok? #f、prompt 不变；合法值 -> 继续
(define-values (cq0 acq0) (resource-request-quit st1))
(check-equal? acq0 '())
(check-equal? (prompt-kind (prompt-of cq0)) 'confirm)
(define cpid (prompt-id (prompt-of cq0)))
(define-values (cq1 acq1 ok3?) (resource-submit-text cq0 cpid "bogus"))
(check-false ok3?)
(check-equal? acq1 '())
(check-equal? cq1 cq0)
(define-values (cq2 acq2 ok4?) (resource-submit-text cq0 cpid " skip "))
(check-true ok4?)
(check-equal? (map resource-action-kind acq2) '(quit))

;;; ---------- 显示路径：根内相对，根外绝对 ----------
(define display-root
  (build-path (find-system-path 'temp-dir) "edit-tui-display-root"))
(define display-store (resource-set-root resource-store-empty display-root))
(check-equal? (resource-root display-store)
              (resource-normalize-path display-root))
(check-equal? (resource-display-path display-store display-root) ".")
(check-equal? (resource-display-path display-store
                                     (build-path display-root "a" "b.txt"))
              "a/b.txt")
(check-equal? (resource-display-path display-store
                                     (build-path (find-system-path 'temp-dir)
                                                 "edit-tui-outside.txt"))
              (resource-normalize-path
               (build-path (find-system-path 'temp-dir)
                           "edit-tui-outside.txt")))
;; 前缀相同但不是根内（root-other 不是 root 的子目录）
(check-equal? (resource-display-path display-store
                                     (build-path (find-system-path 'temp-dir)
                                                 "edit-tui-display-root-other.txt"))
              (resource-normalize-path
               (build-path (find-system-path 'temp-dir)
                           "edit-tui-display-root-other.txt")))

(displayln "edit-tui-rebuild/test/resource.rkt: ok")
