#lang racket

;;; edit/feature/tree.rkt —— 文件树窗口（左侧）
;;;
;;; 目录模型（展开集）/ 列举 / 键位在本模块。树是一篇只读 document，core 的渲染 /
;;; 选区 / 滚动全套照用。**只做列举 / 展开**：不读文件内容、不写盘（无 I/O）。

(require racket/string
         racket/path
         racket/file
         "../command/session.rkt"
         "../command/command.rkt"
         "../command/binding.rkt"
         "../core/keymap.rkt"
         "../../core/text/document.rkt")

(provide tree-install
         (struct-out cmd-tree-activate) (struct-out cmd-tree-new-file)
         (struct-out cmd-tree-toggle))

;;; ---------- 模型 ----------

(struct entry (path name dir? depth) #:transparent)
(struct tree-model (root expanded) #:transparent)

(define (basename p)
  (path->string (or (file-name-from-path (path->complete-path p)) p)))

(define (children dir)
  (with-handlers ([exn:fail? (lambda (_) '())])
    (sort (directory-list dir #:build? #t)
          (lambda (a b)
            (define da (and (directory-exists? a) #t))
            (define db (and (directory-exists? b) #t))
            (cond [(and da (not db)) #t]
                  [(and db (not da)) #f]
                  [else (string<? (basename a) (basename b))])))))

(define (entries m)
  (define (node p depth)
    (define e (entry p (basename p) (directory-exists? p) depth))
    (if (and (entry-dir? e) (hash-ref (tree-model-expanded m) (simplify-path p) #f))
        (cons e (append* (for/list ([c (in-list (children p))]) (node c (add1 depth)))))
        (list e)))
  (node (tree-model-root m) 0))

(define (entry-at-focus s m vid)
  (define line (session-view-point-line s vid))
  (define es (entries m))
  (and (< line (length es)) (list-ref es line)))

(define (tree-document m)
  (define es (entries m))
  (define lines
    (for/list ([e (in-list es)])
      (string-append (make-string (* 2 (entry-depth e)) #\space)
                     (entry-name e)
                     (if (entry-dir? e) "/" ""))))
  (define doc (document-open (string-join lines "\n")))
  (document-face-fill-batch
   doc (for/list ([e (in-list es)] [l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length l)
               (cond [(entry-dir? e) 'tree-dir] [else 'tree-file]))))
  (document-readonly-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length l) #t)))
  doc)

(define (make-refresh m last)
  (lambda (s)
    (define key (entries m))
    (cond [(equal? key (unbox last)) #f]
          [else (set-box! last key) (tree-document m)])))

;;; ---------- 命令 ----------

(struct cmd-tree-activate () #:transparent)
(struct cmd-tree-new-file () #:transparent)
(struct cmd-tree-toggle   () #:transparent)

(define (do-activate s m vid)
  (define e (entry-at-focus s m vid))
  (cond
    [(not e) s]
    [(entry-dir? e)
     (define key (simplify-path (entry-path e)))
     (if (hash-ref (tree-model-expanded m) key #f)
         (hash-remove! (tree-model-expanded m) key)
         (hash-set! (tree-model-expanded m) key #t))
     s]
    [else s]))                             ; 打开文件要读盘 —— 暂不做

(define (tree-handler m vid)
  (lambda (s cmd)
    (and (eqv? vid (session-focus-vid s))
         (cond
           [(cmd-tree-activate? cmd) (do-activate s m vid)]
           [(cmd-tree-new-file? cmd)
            ;; 询问名字；无 I/O，回调只关掉输入行。
            (session-prompt-open s (session-panel-vid s 'input) "new file: "
                                 (lambda (s _name) s))]
           [(cmd-tree-toggle? cmd)
            (session-set-visible s vid (not (presentation-visible? (session-presentation s vid))))]
           [else #f]))))

;;; ---------- 装配 ----------

(define tree-keys
  (kbd
   (key 'up)        (cmd-nav 'up #f)
   (key 'down)      (cmd-nav 'down #f)
   (key 'enter)     (cmd-tree-activate)
   (key 'n 'ctrl)   (cmd-tree-new-file)
   (key 'escape)    (cmd-tree-toggle)
   (key 'tab)       (cmd-panel-swap)))

;; → (values session vid)
(define (tree-install s root width height)
  (define-values (s1 _did vid) (session-add-document s "" width height #:name "*tree*"))
  (define m (tree-model (simplify-path (path->complete-path root)) (make-hash)))
  (hash-set! (tree-model-expanded m) (tree-model-root m) #t)
  (define p (panel 'tree vid (make-refresh m (box #f)) tree-keys 'left))
  (define s2 (session-add-panel s1 p))
  (values (session-add-handler s2 (tree-handler m vid)) vid))
