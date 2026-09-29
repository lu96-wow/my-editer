#lang racket

;;; app.rkt —— 会话状态 + 文档管理
;;;
;;; app 是唯一的状态值。它只装：
;;;   editor       core 的 editor（所有文档 + 视图）
;;;   opened       路径 ↔ 文档 id
;;;   tree         树的私有状态（对壳不透明，树自己解释）
;;;   tree-vid / status-vid / editor-vid   三个视图 id
;;;   focus        当前焦点视图 id（树 ↔ 编辑格）
;;;   rows / cols  尺寸
;;;
;;; **文档管理**（打开 / 显示 / 关闭 / 保存）就在这里，因为它是「中枢」的职责。
;;; 打开 = 换掉编辑格的视图（单格）。关掉正显示的文档 = 换回空 scratch。
;;; 这里没有命令表、没有 intent、没有事件：都是普通函数。
;;;
;;; 注意：状态参数一律叫 a，避免和 struct 类型名 app 撞名。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "fs.rkt"
         racket/file)

(provide (struct-out app)
         app-path
         app-open app-show app-close app-save
         editor-vid-width editor-vid-height)

(struct app (editor opened tree tree-vid status-vid editor-vid focus rows cols)
  #:transparent)
;; tree : any/c（树的私有状态；app.rkt 不解释）

;; 编辑格的尺寸（左树 30 + 1 竖带，底状态栏 1 行）。
(define (editor-vid-width a) (max 1 (- (app-cols a) 31)))
(define (editor-vid-height a) (max 1 (sub1 (app-rows a))))

;; 文档 id → 路径（没有 = scratch）。
(define (app-path a did)
  (for/first ([(p d) (in-hash (app-opened a))] #:when (= d did)) p))

;; 让编辑格显示某个文档：换掉旧视图，装新视图，焦点给编辑格。
(define (app-show a did)
  (define ed (app-editor a))
  (define ed1 (editor-close-view ed (app-editor-vid a)))
  (define-values (ed2 vid)
    (editor-add-view ed1 did (editor-vid-width a) (editor-vid-height a)
                     'free #f #:line-numbers? #t))
  (struct-copy app a [editor ed2] [editor-vid vid] [focus vid]))

;; 打开路径：已开就复用，否则读文件建文档再显示。
(define (app-open a path)
  (define existing (hash-ref (app-opened a) path #f))
  (cond
    [existing (app-show a existing)]
    [else
     (define-values (ed* did)
       (editor-add-document (app-editor a) (fs-read path)
                            (path->string (file-name-from-path path))))
     (app-show (struct-copy app a [editor ed*]
                            [opened (hash-set (app-opened a) path did)])
               did)]))

;; 关闭文档：若是编辑格正显示的，换回一个空 scratch。
(define (app-close a did)
  (define ed (app-editor a))
  (define showing? (= did (editor-view-document-id ed (app-editor-vid a))))
  (define ed1 (if showing? (editor-close-view ed (app-editor-vid a)) ed))
  (define ed2 (editor-close-document ed1 did))
  (define a1 (struct-copy app a [editor ed2]
               [opened (for/hash ([(p d) (in-hash (app-opened a))] #:unless (= d did))
                         (values p d))]))
  (cond
    [showing?
     (define-values (ed3 _did vid)
       (editor-add-document-view ed2 "" (editor-vid-width a) (editor-vid-height a)
                                 "*scratch*" #:line-numbers? #t))
     (struct-copy app a1 [editor ed3] [editor-vid vid] [focus vid])]
    [else a1]))

;; 保存当前编辑格文档（有路径才写）。
(define (app-save a)
  (define ed (app-editor a))
  (define vid (app-editor-vid a))
  (define path (app-path a (editor-view-document-id ed vid)))
  (cond
    [path (display-to-file (editor-view-string ed vid) path #:exists 'replace) a]
    [else a]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "input.rkt")

  (define d (make-temporary-file "rbapp-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\nworld\n" f #:exists 'replace)

  (define ed0 (editor-open "" 10 5 #:line-numbers? #t))
  (define a (app ed0 (hash) #f 99 98 0 0 5 40))

  ;; 打开 → 建文档 + 显示 + 焦点到编辑格
  (define a1 (app-open a f))
  (check-true (hash-has-key? (app-opened a1) f))
  (check-equal? (editor-view-string (app-editor a1) (app-editor-vid a1)) "hello\nworld\n")
  (check-equal? (app-focus a1) (app-editor-vid a1))

  ;; 再打开同一文件 → 复用（文档数不变）
  (define a2 (app-open a1 f))
  (check-equal? (length (editor-documents (app-editor a2)))
                (length (editor-documents (app-editor a1))))

  ;; 保存：改内容后写回
  (define-values (ed* _ch) (editor-view-insert (app-editor a2) (app-editor-vid a2) "X"))
  (define a3 (app-save (struct-copy app a2 [editor ed*])))
  (check-equal? (file->string f) "Xhello\nworld\n")

  ;; 关闭：文档没了，编辑格换 scratch
  (define a4 (app-close a3 (hash-ref (app-opened a3) f)))
  (check-false (hash-has-key? (app-opened a4) f))
  (check-equal? (editor-view-string (app-editor a4) (app-editor-vid a4)) "")

  (delete-directory/files d)
  (displayln "lab-rebuild/app.rkt: all tests passed"))
