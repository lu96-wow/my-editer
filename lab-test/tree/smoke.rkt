#lang racket

;;; lab-test/tree/smoke.rkt —— 两棵自托管树：内容 / 颜色 / 打开 / 删除

(require rackunit racket/file racket/path
         "../../lab/model/session.rkt"
         "../../lab/model/tree.rkt"
         "../../lab/model/ops.rkt"
         "../../lab/model/layout.rkt"
         "../../lab/command/dispatch.rkt"
         "../../lab/protocol.rkt"
         "../../core/editor.rkt")

(define m0 (modifiers #f #f #f #f))
(define mC (modifiers #t #f #f #f))

(define tmp (make-temporary-directory))
(display-to-file "hi" (build-path tmp "a.txt") #:exists 'replace)
(make-directory (build-path tmp "sub"))
(display-to-file "x" (build-path tmp "sub" "b.txt") #:exists 'replace)

(define s0 (trees-init (struct-copy session (session-open "" 60 15 "scratch") [project tmp])))

;; 两个树视图
(define vids (session-tree-vids s0))
(check-equal? (length vids) 2)
(define ftree (tree-of-view s0 (car vids)))
(define dtree (tree-of-view s0 (cadr vids)))
(check-equal? (tree-kind ftree) 'files)
(check-equal? (tree-kind dtree) 'documents)

;; 文件树文本：目录名 + a.txt + sub（缩进区分层次）
(define did-ft (editor-view-document-id (session-editor s0) (car vids)))
(define ft-text (document-text s0 did-ft))
(check-not-false (regexp-match? #rx"a\\.txt" ft-text))
(check-not-false (regexp-match? #rx"sub" ft-text))
;; 子项缩进比根多 2 格
(check-not-false (for/or ([l (in-list (string-split ft-text "\n"))])
                   (string-prefix? l "  ")))

;; 根节点 face = tree-dir（颜色区分类型）
(check-equal? (editor-view-highlight-at (session-editor s0) (car vids) 0 0) 'tree-dir)

;; 文档树包含 scratch，但不含树文档自身
(define did-dt (editor-view-document-id (session-editor s0) (cadr vids)))
(define dt-text (document-text s0 did-dt))
(check-not-false (regexp-match? #rx"scratch" dt-text))
(check-false (regexp-match? #rx"files" dt-text))

;; 单个侧栏：切换显示文件树 / 文档树
(check-equal? (session-sidebar-kind s0) 'files)
(define sw1 (sidebar-switch! s0))
(check-equal? (session-sidebar-kind sw1) 'documents)
(check-equal? (session-active sw1) (cadr vids))
(define sw2 (sidebar-switch! sw1))
(check-equal? (session-sidebar-kind sw2) 'files)
(check-equal? (session-active sw2) (car vids))
;; 侧栏在布局里只占一个 pane（两棵树只显示其一）
(check-equal? (length (filter (lambda (r) (member (pane-rect-id r) vids)) (session-rects s0))) 1)

;; 焦点文件树，光标移到 a.txt，Enter → io-load effect
(define rows (tree-rows ftree))
(define idx (for/first ([n (in-list rows)] [i (in-naturals)]
                        #:when (equal? (tnode-name n) "a.txt"))
             i))
(check-true (exact-nonnegative-integer? idx))
(define s1 (session-focus s0 (car vids)))
(define s2 (view-goto! s1 (car vids) idx 0))
(define-values (s3 effs) (dispatch s2 (key 'enter m0)))
(check-equal? (length effs) 1)
(check-true (io-load? (car effs)))
(check-equal? (io-load-path (car effs)) (path->string (build-path tmp "a.txt")))

;; Ctrl+D：弹确认输入行 → 输入 y → 真删
(define s5 (view-goto! (session-focus s3 (car vids)) (car vids) idx 0))
(define-values (s6 _e6) (dispatch s5 (key #\d mC)))
(check-true (prompt? (session-prompt s6)))
(define-values (s6b _eb) (dispatch s6 (text "y" m0)))
(define-values (s7 _e7) (dispatch s6b (key 'enter m0)))
(check-false (prompt? (session-prompt s7)))
(check-false (file-exists? (build-path tmp "a.txt")))

;; Ctrl+N：弹输入行 → 输入名字 → 建文件（光标移到根行）
(define s7b (view-goto! (session-focus s7 (car vids)) (car vids) 0 0))
(define-values (s8 _e8) (dispatch s7b (key #\n mC)))
(check-true (prompt? (session-prompt s8)))
(define-values (s8b _eb2) (dispatch s8 (text "new.txt" m0)))
(define-values (s9 _e9) (dispatch s8b (key 'enter m0)))
(check-false (prompt? (session-prompt s9)))
(check-true (file-exists? (build-path tmp "new.txt")))

;; --- 鼠标：layout 命中 → 切焦点 / 落光标（layout ⊕ command 的耦合点）---
;; 侧栏 30 + gap 1，文件树在上半（y 0），主编辑区在 x=31，状态栏在 y=14。
(define c1 (click! s0 2 5))
(check-equal? (session-active c1) (car vids))                       ; 点文件树 → 焦点切过去
(check-equal? (editor-view-point-line (session-editor c1) (car vids)) 2)  ; 光标落到点击行
(define c2 (click! s0 2 35))
(check-equal? (session-active c2) 0)                                 ; 点主编辑区 → 焦点切回
(define c3 (click! s0 14 5))
(check-equal? (session-active c3) (session-active c2))              ; 点状态栏 → 焦点不变

;; 经过派发层的鼠标路径（含 trees-refresh）
(define d1 (call-with-values (lambda () (dispatch s0 (mouse 'press 'left 2 5 m0)))
              (lambda (s _e) s)))
(check-equal? (session-active d1) (car vids))

(delete-directory/files tmp)
(printf "ALL TREE SMOKE OK\n")
