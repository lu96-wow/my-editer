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

(define state0 (make-app-state #:area (rect 0 0 40 10) #:root (path->string root)))
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

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/filetree.rkt: ok")
