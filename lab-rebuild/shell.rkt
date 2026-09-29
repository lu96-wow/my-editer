#lang racket

;;; shell.rkt —— 壳：布局 + 焦点 + 输入路由 + 渲染
;;;
;;; 壳只做三件事：
;;;   1) 把输入路由给焦点文档（树 or 编辑格）；
;;;   2) 焦点切换（唯一壳级职责）；
;;;   3) 每帧投影状态栏，把 rects 交给 core 渲染。
;;;
;;; 它不认识任何命令、不碰文档内容、不持有后端。后端（终端/GUI）在更外面，
;;; 只把 native 事件翻译成 input.rkt 的类型，并把 core 的 screen 画出来。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "app.rkt"
         "tree.rkt"
         "buffer.rkt"
         "status.rkt"
         "input.rkt")

(provide setup handle render focus-toggle?)

;;; ---------- 组装 ----------

(define (setup root rows cols)
  (define ch (max 1 (sub1 rows)))
  (define ed0 (editor-open "" 40 ch #:line-numbers? #t))                        ; scratch = did0 vid0
  (define-values (ed1 _tdid tvid) (editor-add-document-view ed0 "" 30 ch "*tree*" #:line-numbers? #f))
  (define-values (ed2 _sdid svid) (editor-add-document-view ed1 "" cols 1 "*status*" #:line-numbers? #f))
  (define a (app ed2 (hash) (tree-open root) tvid svid 0 0 rows cols))
  (tree-project! a))

;;; ---------- 焦点切换（壳自己的唯一键） ----------

(define (focus-toggle-key? k)
  (and (key? k) (key-ctrl? k) (not (key-alt? k)) (not (key-meta? k))
       (eqv? (key-name k) #\o)))

(define (focus-toggle? in) (and (key? in) (focus-toggle-key? in)))

;;; ---------- 输入路由 ----------

(define (handle a in)
  (cond
    [(resize? in) (struct-copy app a [rows (resize-rows in)] [cols (resize-cols in)])]
    [(focus-toggle? in)
     (struct-copy app a [focus (if (= (app-focus a) (app-tree-vid a))
                                   (app-editor-vid a)
                                   (app-tree-vid a))])]
    [(= (app-focus a) (app-tree-vid a)) (tree-input a in)]
    [else (buffer-input a in)]))

;;; ---------- 渲染 ----------

(define (render a)
  (define a1 (status-project! a))
  (define ch (max 1 (sub1 (app-rows a1))))
  (define tw (max 1 (min 30 (app-cols a1))))
  (define ex (+ tw 1))
  (define ew (max 1 (- (app-cols a1) ex)))
  (define rects (list (rect (app-tree-vid a1) 0 0 tw ch)
                      (rect (app-editor-vid a1) ex 0 ew ch)
                      (rect (app-status-vid a1) 0 ch (app-cols a1) 1)))
  (define ed (editor-set-layout (app-editor a1) rects))
  (define a2 (struct-copy app a1 [editor ed]))
  (values a2 (editor-render-layout ed rects (app-focus a2) (app-cols a2) (app-rows a2))))

;;; ---------- 测试（headless：喂 input，看 screen） ----------

(module+ test
  (require rackunit
           "../core/view/base/screen.rkt"
           racket/file)

  (define d (make-temporary-file "rbshell-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\nworld\n" f #:exists 'replace)

  (define a0 (setup d 10 60))
  (define-values (_a screen0) (render a0))
  (check-equal? (screen-width screen0) 60)
  (check-equal? (screen-height screen0) 10)
  ;; 树在左列显示根路径；状态栏在底行
  (check-true (for/or ([rn (in-list (screen-row screen0 0))]) (regexp-match? #rx"rbshell" (run-text rn))))
  (check-true (for/or ([rn (in-list (screen-row screen0 9))]) (eq? (run-face rn) 'status)))

  ;; 焦点在编辑格：打字
  (define a1 (handle a0 (key #\X #f #f #f #f)))
  (check-equal? (substring (editor-view-string (app-editor a1) (app-editor-vid a1)) 0 1) "X")

  ;; 切到树 → 下移到 a.txt → 回车打开
  (define a2 (handle a1 (key #\o #t #f #f #f)))
  (check-equal? (app-focus a2) (app-tree-vid a2))
  (define a3 (handle a2 (key 'down #f #f #f #f)))
  (define a4 (handle a3 (key 'enter #f #f #f #f)))
  (check-equal? (editor-view-string (app-editor a4) (app-editor-vid a4)) "hello\nworld\n")
  (check-equal? (app-focus a4) (app-editor-vid a4))

  ;; 树里新建文件：文档里出现提示行 → 敲名字 → 回车
  (define a5 (handle a4 (key #\o #t #f #f #f)))                 ; 焦点回树
  (define a6 (handle a5 (key 'up #f #f #f #f)))                 ; → 根行
  (define a7 (handle a6 (key #\n #f #f #f #f)))                 ; 提示：新建文件
  (check-true (regexp-match? #rx"新建文件" (editor-view-string (app-editor a7) (app-tree-vid a7))))
  (define a8 (handle a7 (text "made")))                         ; 用户就地在文档里敲
  (define a9 (handle a8 (key 'enter #f #f #f #f)))
  (check-true (file-exists? (build-path d "made")))
  (check-false (regexp-match? #rx"新建文件" (editor-view-string (app-editor a9) (app-tree-vid a9))))

  ;; 状态栏投影焦点信息（此时焦点在树 → 显示"文件树"）
  (define-values (a10 screen10) (render a9))
  (check-true (for/or ([rn (in-list (screen-row screen10 9))]) (regexp-match? #rx"文件树" (run-text rn))))

  ;; resize
  (define a11 (handle a10 (resize 14 40)))
  (define-values (_a12 screen12) (render a11))
  (check-equal? (screen-width screen12) 40)
  (check-equal? (screen-height screen12) 14)

  (delete-directory/files d)
  (displayln "lab-rebuild/shell.rkt: all tests passed"))
