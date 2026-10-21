#lang racket

;;; 文件树：行投影 / 展开 / 打开文件 -> placement。
(require rackunit
         racket/async-channel
         racket/file
         racket/path
         "../config/keymap/default.rkt"
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
                               #:keymap default-keymap))
(define state1 (filetree-install-state state0 10 root
                                       #:panel-stack filetree-panel-stack))
(define state2 (sync-filetree! state1 engine))

(define f (hash-ref (app-state-store state2) 'filetree))
(define rows (filetree-rows f))
(check-true (> (length rows) 0))
(check-equal? (filetree-line-kind (car rows)) 'root)
;; 文件树根显示绝对路径，不走 resource-display-path 的相对路径显示
(check-equal? (resource-root (app-state-resources state2))
              (resource-normalize-path root))
(check-equal? (filetree-line-text (car rows))
              (resource-normalize-path root))

(define (find-row pred)
  (for/first ([l (in-list rows)] [i (in-naturals)] #:when (pred l)) i))

(define sub-i (find-row (λ (l) (and (eq? (filetree-line-kind l) 'dir)
                                    (string=? (path->string (file-name-from-path (filetree-line-path l))) "sub")))))
(check-not-false sub-i)

(define (set-cursor state line)
  (define f (hash-ref (app-state-store state) 'filetree))
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree
                                (filetree-set-cursor f line))]))

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
;; 打开路径会进入 filetree 的 opened 缓存。
(define state8b (sync-filetree! state8 engine))
(define f8 (hash-ref (app-state-store state8b) 'filetree))
(define opened-path (resource-path (app-state-resources state8b) 1))
(check-true (hash-has-key? (filetree-opened f8) opened-path))
(check-equal? (filetree-opened-revision f8)
              (resource-opened-revision (app-state-resources state8b)))
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
(display-to-file "dot" (build-path root2 ".dot.txt") #:exists 'truncate)
(define c0 (filetree-install-state
            (make-app-state #:area (rect 0 0 40 10)
                            #:keymap default-keymap)
            10 root2
            #:panel-stack filetree-panel-stack))
(define c1 (sync-filetree! c0 engine))
(define n1 (length (rows-of c1)))
(check-true (> n1 1))
;; 默认隐藏 . 开头条目
(check-false (for/or ([l (in-list (rows-of c1))])
              (string=? (path->string (file-name-from-path (filetree-line-path l)))
                        ".dot.txt")))
;; 输入完全没变：sync 整段跳过，返回同一个 state 对象。
(check-eq? c1 (sync-filetree! c1 engine))

;; 磁盘上新加文件：投影输入没变 -> 不重扫，看不到
(display-to-file "y" (build-path root2 "b.txt") #:exists 'truncate)
(define c2 (sync-filetree! c1 engine))
(check-eq? c1 c2)
(check-equal? (length (rows-of c2)) n1)

;; C-r 丢弃缓存 -> 下一次 sync 重新扫
(define-values (c3 _a) (filetree-refresh-command c2))
(define c4 (sync-filetree! c3 engine))
(check-equal? (length (rows-of c4)) (add1 n1))

;; C-h：显示 . 开头条目
(define-values (c5 _a5) (filetree-toggle-hidden-command c4))
(define c6 (sync-filetree! c5 engine))
(check-equal? (length (rows-of c6)) (add1 (length (rows-of c4))))
(check-true (for/or ([l (in-list (rows-of c6))])
              (string=? (path->string (file-name-from-path (filetree-line-path l)))
                        ".dot.txt")))

;; 异步扫描：sync 只提交 job；结果回来前保留旧 rows，结果校验后下一帧写入。
(define async0 (filetree-install-state
                (make-app-state #:area (rect 0 0 40 10)
                                #:keymap default-keymap)
                10 root2
                #:panel-stack filetree-panel-stack))
(define async1 (sync-filetree! async0 engine #:async? #t))
(define scan-jobs (job-pending (app-state-jobs async1)))
(check-true (pair? scan-jobs))
(check-equal? (rows-of async1) '())
(define rt (start-job-runtime filetree-services #:workers 1))
(dispatch-jobs! rt (app-state-jobs async1))
(define scan-ev (async-channel-get (job-runtime-event-channel rt)))
(stop-job-runtime rt)
(define async2
  (handle-filetree-job-result
   (app-state-finish-job async1
                         (job-result-event-id scan-ev)
                         (job-result-event-result scan-ev))
   scan-ev))
(define async3 (sync-filetree! async2 engine #:async? #t))
(check-true (> (length (rows-of async3)) 1))
(delete-directory/files root2)

;; 光标在 view 上：导航表覆盖四个方向 + Home/End（普通 buffer 语义）
(for ([k (in-list (list (key 'left) (key 'right) (key 'up) (key 'down)
                        (key 'home) (key 'end)))])
  (define-values (status _v) (command-table-lookup filetree-command-table (list k)))
  (check-equal? status 'command (key->string k)))
;; Enter / C-r / C-h 仍然是文件树自己的
(define-values (enter-status _v) (command-table-lookup filetree-command-table (list (key 'enter))))
(check-equal? enter-status 'command)
(define-values (hidden-status _hidden-v) (command-table-lookup filetree-command-table (list (key 'h 'ctrl))))
(check-equal? hidden-status 'command)

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/filetree.rkt: ok")
