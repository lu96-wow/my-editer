#lang racket

;;; lab-test/tree/open.rkt —— 默认无文档 + 文件树打开 / 删除（含幽灵文档清理）

(require rackunit racket/file racket/path
         "../../lab/model/session.rkt"
         "../../lab/model/tree.rkt"
         "../../lab/model/document.rkt"
         "../../lab/model/edit.rkt"
         "../../lab/command/dispatch.rkt"
         "../../lab/input.rkt"
         "../../lab/effect.rkt"
         "../../lab/driver.rkt"
         "../../core/editor.rkt")

(define m0 (modifiers #f #f #f #f))
(define mC (modifiers #t #f #f #f))

(define tmp (make-temporary-directory))
(define file (build-path tmp "a.txt"))
(display-to-file "line1\nline2\n" file #:exists 'replace)

;; 空白会话 + 两棵树 → 默认没有任何编辑器文档
(define s0 (trees-init (session-blank 60 15 tmp)))
(check-equal? (hash-count (session-docs s0)) 2)                 ; 只有两棵树
(check-equal? (editor-view-count (session-editor s0)) 2)

(define vids (session-tree-vids s0))
(define ftree (tree-of-view s0 (car vids)))
(define idx (for/first ([n (in-list (tree-rows ftree))] [i (in-naturals)]
                        #:when (equal? (tnode-name n) "a.txt"))
             i))
(check-true (exact-nonnegative-integer? idx))

;; 文件树 Enter → io-load effect → 执行 → 新文档
(define s1 (view-goto! (session-focus s0 (car vids)) (car vids) idx 0))
(define-values (s2 effs) (dispatch s1 (key 'enter m0)))
(check-equal? (length effs) 1)
(check-true (io-load? (car effs)))
(define-values (s3 q?) (execute-effects s2 effs))
(check-false q?)
(check-equal? (hash-count (session-docs s3)) 3)                 ; 两棵树 + a.txt
(define did (for/first ([d (in-hash-keys (session-docs s3))]
                        #:when (equal? (document-name s3 d) "a.txt"))
              d))
(check-equal? (document-text s3 did) "line1\nline2\n")
(check-equal? (document-path s3 did) (path->string file))

;; 刷新后 a.txt 标为已打开（tree-open）
(define s4 (trees-refresh s3))
(define ft4 (tree-of-view s4 (car vids)))
(define idx4 (for/first ([n (in-list (tree-rows ft4))] [i (in-naturals)]
                         #:when (equal? (tnode-name n) "a.txt"))
              i))
(check-equal? (editor-view-highlight-at (session-editor s4) (car vids) idx4 0) 'tree-open)

;; 删除已打开的文件 → 文档一并关掉（无幽灵）
(define s5 (view-goto! (session-focus s4 (car vids)) (car vids) idx4 0))
(define-values (s6 _e6) (dispatch s5 (key #\d mC)))
(define-values (s7 _e7) (dispatch s6 (text "y" m0)))
(define-values (s8 _e8) (dispatch s7 (key 'enter m0)))
(check-equal? (hash-count (session-docs s8)) 2)                 ; 回到两棵树
(check-false (for/or ([d (in-hash-keys (session-docs s8))]
                      #:when (equal? (document-path s8 d) (path->string file)))
               #t))
(check-false (file-exists? file))

(delete-directory/files tmp)
(printf "ALL OPEN OK\n")
