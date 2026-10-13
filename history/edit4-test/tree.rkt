#lang racket

;;; edit4-test/tree.rkt —— 文件树资源（纯操作 + 交互命令 + 投影）

(require rackunit
         racket/list racket/file racket/path
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/tree.rkt"
         "../edit4/content/fs.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/view/tree.rkt"
         "../edit4/view/panel.rkt"
         "../edit4/boot.rkt")

;;; ---------- 临时目录：a.txt / .h.txt / sub/b.txt ----------

(define dir (simplify-path (make-temporary-file "ed4tree~a" 'directory)))
(define sub (build-path dir "sub"))
(display-to-file "a\n" (build-path dir "a.txt") #:exists 'truncate)
(display-to-file "h\n" (build-path dir ".h.txt") #:exists 'truncate)
(make-directory sub)
(display-to-file "b\n" (build-path sub "b.txt") #:exists 'truncate)

;;; ---------- fs 原语（make / delete） ----------

(define nf (build-path dir "new.txt"))
(fs-make-file nf)
(check-true (fs-file? nf))
(fs-delete nf)
(check-false (fs-file? nf))
(define nd (build-path dir "nd"))
(fs-make-dir nd)
(check-true (fs-dir? nd))
(fs-delete nd)
(check-false (fs-dir? nd))

;;; ---------- 纯操作 ----------

(define (row-names ts) (map cadr (tree-rows ts)))
(define (row-index ts p)
  (for/first ([r (in-list (tree-rows ts))] [i (in-naturals)]
              #:when (equal? (path-key (car r)) (path-key p)))
    i))

(define ts (tree-ensure (tree-init dir)))
(check-not-false (member "a.txt" (row-names ts)))
(check-not-false (member "sub" (row-names ts)))
(check-false (member ".h.txt" (row-names ts)))                 ; hidden 默认不显示
(check-not-false (member ".h.txt" (row-names (tree-toggle-hidden ts))))
;; 展开 sub → 读目录 → b.txt 出现
(check-not-false (member "b.txt" (row-names (tree-ensure (tree-toggle-dir ts sub)))))
;; parent
(check-equal? (path-key (tree-parent-dir sub)) (path-key dir))
;; refresh 清缓存
(check-equal? (tree-children (tree-refresh ts)) (hash))

;;; ---------- 交互命令（经 dispatch；作用域走 content-scopes） ----------

(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))  ; 与 app 一致
(define SZ (cons 80 24))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list))

;; 造一个「树面板内容已写回、光标可定位」的世界（runtime 每帧也会先 commit-panels!）。
(define (tree-world)
  (define w (boot #:root dir))
  (define c (world-content w))
  (define ed (content-ed c))
  (commit-panels! ed (project-panels base-panels w))
  (define tv (content-panel-vid c "*tree*"))
  (define tw (for/first ([id (in-list (ids (world-layout w)))]
                         #:when (eqv? (content-vid-of c id) tv))
               id))
  (values w c ed tv tw))

;; enter 目录 → 展开 + reload effect
(define-values (w0 c0 ed0 tvid tree-wid) (tree-world))
(set-point! ed0 tvid (row-index (content-tree c0) sub) 0)
(define r1 (run (world-set-focus w0 tree-wid) (key-event 'enter '())))
(check-true (hash-has-key? (tree-expanded (content-tree (world-content (car r1)))) sub))
(check-true (for/or ([e (in-list (cadr r1))]) (reload-tree? e)))

;; enter 文件 → open-file effect
(define-values (wa ca eda tva twa) (tree-world))
(set-point! eda tva (row-index (content-tree ca) (build-path dir "a.txt")) 0)
(define r2 (run (world-set-focus wa twa) (key-event 'enter '())))
(check-true (for/or ([e (in-list (cadr r2))])
              (and (open-file? e)
                   (equal? (path-key (open-file-path e)) (path-key (build-path dir "a.txt"))))))

;; 编辑器作用域下 enter 不是 tree-enter（走 insert-text，不产 open-file）
(define-values (we ce ede tve twe) (tree-world))
(define editor-wid
  (for/first ([id (in-list (ids (world-layout we)))]
              #:when (eqv? (content-vid-of ce id) (content-vid-of ce 0)))
    id))
(define r3 (run (world-set-focus we editor-wid) (key-event 'enter '())))
(check-false (for/or ([e (in-list (cadr r3))]) (open-file? e)))

;;; ---------- 投影：目录加 "/"、着色 ----------

(define-values (text faces) (tree-content w0 tvid))
(check-true (regexp-match? #rx"sub/" text))
(check-equal? (cdr (for/first ([f (in-list faces)]
                               #:when (equal? (car f) (row-index (content-tree c0) sub)))
                     f))
              'tree-dir)

;;; ---------- 打开复用：同路径只有一个 doc ----------

(define-values (c1 _d1 _v1) (content-add-doc! c0 "x" 20 5 "a" (build-path dir "a.txt")))
(check-not-false (content-doc-by-path c1 (build-path dir "a.txt")))
(check-equal? (length (content-doc-paths c1)) 1)

(displayln "edit4/tree.rkt: all tests passed")
