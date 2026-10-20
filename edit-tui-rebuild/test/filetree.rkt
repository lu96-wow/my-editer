#lang racket

;;; 文件树：行投影 / 展开 / 打开文件 -> placement。
(require rackunit
         racket/file
         racket/path
         "../main.rkt")

(define root (make-temporary-file "edit-tui-filetree-~a" 'directory))
(define sub (build-path root "sub"))
(make-directory* sub)
(display-to-file "hello" (build-path root "a.txt") #:exists 'truncate)
(display-to-file "world" (build-path sub "b.txt") #:exists 'truncate)

(define engine (make-engine))
(void (engine-create-buffer! engine 10 "*filetree*" ""))
(void (engine-create-view! engine 10 10))

(define state0 (make-app-state #:area (rect 0 0 40 10)
                               #:root (path->string root)
                               #:editor-tables (list edit-command-table)))
(define state1 (filetree-install-state state0 10 root))
(define state2 (sync-filetree! state1 engine))

(define f (hash-ref (app-state-store state2) 'filetree))
(define rows (filetree-rows f))
(check-true (> (length rows) 0))
(check-equal? (filetree-line-kind (car rows)) 'root)
(check-true (string-contains? (filetree-line-text (car rows))
                              (path->string (simplify-path (path->complete-path root)))))

(define (find-row pred)
  (for/first ([l (in-list rows)] [i (in-naturals)] #:when (pred l)) i))

(define sub-i (find-row (λ (l) (and (eq? (filetree-line-kind l) 'dir)
                                    (string=? (path->string (file-name-from-path (filetree-line-path l))) "sub")))))
(check-not-false sub-i)

(define (set-cursor state line)
  (define f (hash-ref (app-state-store state) 'filetree))
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree
                                (filetree-set-line f line))]))

(define state3 (set-cursor state2 sub-i))
(define-values (state4 a4) (filetree-enter-command state3))
(check-equal? a4 '())
(define state5 (sync-filetree! state4 engine))
(define rows2 (filetree-rows (hash-ref (app-state-store state5) 'filetree)))
(check-true (for/or ([l (in-list rows2)])
              (equal? (filetree-line-kind l) 'file)))

;; 打开 a.txt -> open-file-action -> placement
(define a-i (for/first ([l (in-list rows2)] [i (in-naturals)]
                        #:when (and (eq? (filetree-line-kind l) 'file)
                                    (string=? (path->string (file-name-from-path (filetree-line-path l)))
                                              "a.txt")))
              i))
(check-not-false a-i)
(define state6 (set-cursor state5 a-i))
(define-values (state7 a7) (filetree-enter-command state6))
(check-equal? (length a7) 1)
(check-true (open-file-action? (car a7)))

(define state8 (run-actions state7 engine a7))
(check-not-false (app-state-placement state8))
(check-equal? (length (resource-list (app-state-resources state8))) 1)
(check-true (string-contains? (engine-doc-text engine 1) "hello"))
;; 新文档拿到 app 的默认 editor 键表（编辑操作表）：
;; resource-open 会把 tables 合并成一张，所以查 binding 而不是比 eq?。
(define opened-stack (resource-command-stack (app-state-resources state8) 1))
(for ([k (in-list (list (key 'enter) (key 'backspace) (key 'left)))])
  (define-values (status value) (command-table-stack-lookup opened-stack (list k)))
  (void value)
  (check-equal? status 'command))

(define (rows-of st)
  (filetree-rows (hash-ref (app-state-store st) 'filetree)))

;;; ---------- 行投影缓存：同一投影不重扫，C-r 强制刷新 ----------
(define root2 (make-temporary-file "edit-tui-cache-~a" 'directory))
(display-to-file "x" (build-path root2 "a.txt") #:exists 'truncate)
(define c0 (filetree-install-state
            (make-app-state #:area (rect 0 0 40 10) #:root (path->string root2))
            10 root2))
(define c1 (sync-filetree! c0 engine))
(define n1 (length (rows-of c1)))
(check-true (> n1 1))

;; 磁盘上新加文件：投影输入没变 -> 不重扫，看不到
(display-to-file "y" (build-path root2 "b.txt") #:exists 'truncate)
(define c2 (sync-filetree! c1 engine))
(check-equal? (length (rows-of c2)) n1)

;; C-r 丢弃缓存 -> 下一次 sync 重新扫
(define-values (c3 _a) (filetree-refresh-command c2))
(define c4 (sync-filetree! c3 engine))
(check-equal? (length (rows-of c4)) (add1 n1))
(delete-directory/files root2)

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/filetree.rkt: ok")
