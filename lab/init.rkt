#lang racket

;;; ============================================================================
;;; init.rkt —— 装配：把各块接起来（构造初始状态，产出 screen）
;;; ============================================================================
;;;
;;; 这是组合根，不属于三块（编辑器主体 / 命令 / 状态栏）里的任何一块。
;;;
;;;   setup  : 建 core 视图、pane 表、布局、app；树投影一次
;;;   render : 投影状态栏 → layout 解析成 core rects → core 渲染
;;;
;;; 重新导出 handle（命令块），这样后端只需要 require init.rkt。

(require "../core/editor.rkt"
         "editor.rkt"
         "layout.rkt"
         "tree.rkt"
         "status.rkt"
         "command.rkt"
         "input.rkt")

(provide setup render handle)

;;; ---------- 组装 ----------

(define (setup root rows cols)
  (define ch (max 1 (sub1 rows)))
  (define ed0 (editor-open "" 40 ch #:line-numbers? #t))                        ; 编辑格初始视图 = vid0
  (define-values (ed1 _tdid tvid) (editor-add-document-view ed0 "" 10 ch "*tree*" #:line-numbers? #f))
  (define-values (ed2 _sdid svid) (editor-add-document-view ed1 "" cols 1 "*status*" #:line-numbers? #f))
  (define panes (hash 0 (pane 'tree tvid (tree-open root) tree-input tree-pointer #t)
                      1 (pane 'editor 0 #f buffer-input buffer-pointer #t)
                      2 (pane 'status svid #f #f #f #f)))
  ;; 左：文件树固定 10 列，占满整列；右：编辑格 + 状态栏
  (define layout (hsplit-left 10 (lpane 0) (vsplit-bottom 1 (lpane 1) (lpane 2)) 1))
  (define a (app ed2 (hash) panes layout 1 1 rows cols #f #f (quote ())))
  (tree-project! a 0))

;;; ---------- 渲染 ----------

(define (render a)
  (define a1 (status-project! a (app-pid-of-kind a 'status)))
  (define lrs (layout->rects (app-layout a1) 0 0 (app-cols a1) (app-rows a1)))
  (define rects (for/list ([r (in-list lrs)])
                  (rect (app-pane-vid a1 (lrect-id r)) (lrect-x r) (lrect-y r) (lrect-w r) (lrect-h r))))
  (define ed (editor-set-layout (app-editor a1) rects))
  (define a2 (struct-copy app a1 [editor ed]))
  (values a2 (editor-render-layout ed rects (app-focus-vid a2) (app-cols a2) (app-rows a2))))

;;; ============================================================================
;;; 集成测试（headless：喂 input，看 screen）
;;; ============================================================================

(module+ test
  (require rackunit
           "../core/view/base/screen.rkt"
           "../core/text/document.rkt"
           racket/file)

  (define d (make-temporary-file "rbinit-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\nworld\n" f #:exists 'replace)

  (define a0 (setup d 10 60))
  (define-values (_a screen0) (render a0))
  (check-equal? (screen-width screen0) 60)
  (check-equal? (screen-height screen0) 10)
  ;; 树占左列（宽 10），首行是根（face = tree-dir）
  (check-true (for/or ([rn (in-list (screen-row screen0 0))]) (eq? (run-face rn) 'tree-dir)))
  (check-true (for/or ([rn (in-list (screen-row screen0 9))]) (eq? (run-face rn) 'status)))

  ;; 编辑格打字
  (define a1 (handle a0 (key #\X #f #f #f #f)))
  (check-equal? (substring (editor-view-string (app-editor a1) (app-pane-vid a1 1)) 0 1) "X")

  ;; 点树切焦点 → 下移 → 回车打开
  (define a2 (handle a1 (pointer 'press 'left 0 5 #f #f #f #f)))
  (check-equal? (app-focus a2) 0)
  (define a4 (handle (handle a2 (key 'down #f #f #f #f)) (key 'enter #f #f #f #f)))
  (check-equal? (editor-view-string (app-editor a4) (app-pane-vid a4 1)) "hello\nworld\n")
  (check-equal? (app-focus a4) 0)                                   ; 打开不抢焦点
  (check-eq? (document-highlight-at (editor-view-document (app-editor a4) (app-pane-vid a4 0)) 1 4)
             'tree-open)

  ;; 树里新建文件（提示 = 文档里一行）
  (define a7 (handle a4 (key #\n #f #f #f #f)))
  (check-true (regexp-match? #rx"新建文件" (editor-view-string (app-editor a7) (app-pane-vid a7 0))))
  (define a9 (handle (handle a7 (text "made")) (key 'enter #f #f #f #f)))
  (check-true (file-exists? (build-path d "made")))

  ;; 状态栏显示编辑格文档
  (define-values (_a10 screen10) (render a9))
  (check-true (for/or ([rn (in-list (screen-row screen10 9))]) (regexp-match? #rx"a.txt" (run-text rn))))

  ;; resize
  (define a11 (handle a9 (resize 14 40)))
  (define-values (_a12 screen12) (render a11))
  (check-equal? (screen-width screen12) 40)
  (check-equal? (screen-height screen12) 14)

  ;; 视图表：v 切换 → 回车把选中视图显示到编辑格并聚焦（可编辑）→ v 切回文件树
  (check-equal? (app-focus a11) 0)                          ; 焦点还在树上
  (define v1 (handle a11 (key #\v #f #f #f #f)))
  (check-eq? (tree-mode (pane-state (app-pane v1 0))) 'views)
  (check-true (regexp-match? #rx"a.txt"
                (editor-view-string (app-editor v1) (app-pane-vid v1 0))))
  (define v2 (handle v1 (key 'enter #f #f #f #f)))
  (check-equal? (app-focus v2) 1)                           ; 选中视图 → 编辑格获焦
  (check-equal? (editor-view-string (app-editor v2) (app-pane-vid v2 1)) "hello\nworld\n")
  (define v3 (handle (focus-set v2 0) (key #\v #f #f #f #f)))
  (check-eq? (tree-mode (pane-state (app-pane v3 0))) 'files)

  (delete-directory/files d)
  (displayln "lab-rebuild/init.rkt: all tests passed"))
