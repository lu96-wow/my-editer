#lang racket

;;; tree.rkt —— 文件树：**一个普通文档** + 文档管理 + 焦点
;;;
;;; 树自己维护自己的 core 文档：列表行由它写入；需要输入时，就在文档里插一行
;;; （提示只读），用户直接把光标移过去往文档里敲，树读这一行、然后清理。
;;; 没有额外的输入缓冲、没有状态栏耦合。
;;;
;;; 树也是「中枢」：它调 app.rkt 的文档管理来开/关文件，并把焦点交给编辑格。
;;; 状态参数叫 a（避免和 struct 类型名 app 撞名）。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/range.rkt"
         "app.rkt"
         "fs.rkt"
         "input.rkt")

(provide (struct-out tree)
         tree-open
         tree-project!
         tree-input
         tree-lines)

;;; ---------- 状态 ----------

(struct tree (root expanded children prompt) #:transparent)
(struct prompt (kind label data) #:transparent)
;; kind : 'file | 'dir | 'delete
;; data : file/dir → 目标目录；delete → 目标路径

(define (list-dir dir)
  (sort (fs-list dir)
        (lambda (x y)
          (cond [(and (entry-dir? x) (not (entry-dir? y))) #t]
                [(and (entry-dir? y) (not (entry-dir? x))) #f]
                [else (string<? (entry-name x) (entry-name y))]))))

(define (tree-open root)
  (define r (canon-path (if (path? root) root (string->path root))))
  (define re (entry (path->string r) r #t))          ; 根显示绝对路径
  (tree re (hash r #t) (hash r (list-dir r)) #f))

;;; ---------- 可见行 ----------

(define (visible-of t)
  (define (walk e d)
    (cons (cons d e)
          (if (and (entry-dir? e) (hash-has-key? (tree-expanded t) (entry-path e)))
              (append* (for/list ([k (in-list (hash-ref (tree-children t) (entry-path e)))])
                         (walk k (add1 d))))
              '())))
  (walk (tree-root t) 0))

(define (tree-lines t)
  (for/list ([d.e (in-list (visible-of t))])
    (define e (cdr d.e))
    (string-append (make-string (* 2 (car d.e)) #\space)
                   (if (entry-dir? e)
                       (if (hash-has-key? (tree-expanded t) (entry-path e)) "▾ " "▸ ")
                       "  ")
                   (entry-name e))))

(define (tree-line-entry t line)
  (define vis (visible-of t))
  (and (>= line 0) (< line (length vis)) (cdr (list-ref vis line))))

(define (tree-line-of t path)
  (for/first ([v (in-list (visible-of t))] [i (in-naturals)]
              #:when (equal? (entry-path (cdr v)) path)) i))

;;; ---------- 把列表写进自己的文档 ----------

(define (tree-project! a)
  (define lines (tree-lines (app-tree a)))
  (define doc (document-open (if (null? lines) "" (string-join lines "\n"))))
  (struct-copy app a [editor (editor-view-assign (app-editor a) (app-tree-vid a) doc)]))

;;; ---------- 焦点处的 entry ----------

(define (tree-cursor-line a)
  (editor-view-point-line (app-editor a) (app-tree-vid a)))

(define (tree-cur-entry a)
  (tree-line-entry (app-tree a) (tree-cursor-line a)))

(define (tree-target-dir a)
  (define e (tree-cur-entry a))
  (define root (entry-path (tree-root (app-tree a))))
  (cond
    [(not e) root]
    [(entry-dir? e) (entry-path e)]
    [else (canon-path (let-values ([(base _n _d) (split-path (entry-path e))]) base))]))

;;; ---------- 编辑器小助手（只作用于树自己的视图） ----------

(define (tree-do a f)
  (define ed (app-editor a))
  (define vid (app-tree-vid a))
  (define ed* (call-with-values (lambda () (f ed vid)) (lambda (v . _) v)))
  (struct-copy app a [editor ed*]))

(define (tree-goto a line)
  (tree-do a (lambda (e v) (editor-view-set-point e v (point line 0)))))

;;; ---------- 提示行 ----------

(define (prompt-active? t) (and (tree-prompt t) #t))

(define (prompt-value a)
  (define p (tree-prompt (app-tree a)))
  (define lines (string-split (editor-view-string (app-editor a) (app-tree-vid a)) "\n" #:trim? #f))
  (define ln (last lines))
  (substring ln (min (string-length ln) (string-length (prompt-label p)))))

;; 在文档末尾插一行提示（标签只读），光标放到标签后。
(define (prompt-start a kind label data)
  (define ed (app-editor a))
  (define vid (app-tree-vid a))
  (define lines (string-split (editor-view-string ed vid) "\n" #:trim? #f))
  (define last (sub1 (length lines)))
  (define col (string-length (list-ref lines last)))
  (define ed1 (editor-view-set-point ed vid (point last col)))
  (define ed2 (car (call-with-values (lambda () (editor-view-insert ed1 vid (string-append "\n" label))) list)))
  (define line (add1 last))
  (define ed3 (editor-view-set-point ed2 vid (point line (string-length label))))
  (define ed4 (editor-view-readonly-range ed3 vid
               (range-of (point line 0) (point line (string-length label))) #t))
  (struct-copy app a
    [editor ed4]
    [tree (struct-copy tree (app-tree a) [prompt (prompt kind label data)])]))

(define (prompt-clear a)
  (struct-copy app a [tree (struct-copy tree (app-tree a) [prompt #f])]))

;; 读值、执行、清理。
(define (prompt-confirm a)
  (define p (tree-prompt (app-tree a)))
  (define val (prompt-value a))
  (define a1 (prompt-clear a))
  (define result-path
    (case (prompt-kind p)
      [(file) (and (not (string=? val ""))
                   (let* ([dir (prompt-data p)]
                          [path (build-path dir (unique-name dir val))])
                     (fs-create path) path))]
      [(dir) (and (not (string=? val ""))
                  (let* ([dir (prompt-data p)]
                         [path (build-path dir (unique-name dir val))])
                    (fs-mkdir path) path))]
      [(delete) (and (string-ci=? val "y")
                     (begin (fs-delete (prompt-data p)) (prompt-data p)))]
      [else #f]))
  ;; 删除的若正被打开 → 关文档
  (define a2
    (if (and (eq? (prompt-kind p) 'delete) result-path)
        (let ([did (for/first ([(path d) (in-hash (app-opened a1))] #:when (equal? path result-path)) d)])
          (if did (app-close a1 did) a1))
        a1))
  ;; 刷新被改动的目录
  (define a3
    (if (and result-path (memq (prompt-kind p) '(file dir)))
        (let* ([dir (prompt-data p)]
               [children (hash-set (tree-children (app-tree a2)) dir (list-dir dir))])
          (struct-copy app a2 [tree (struct-copy tree (app-tree a2) [children children])]))
        a2))
  (define a4 (tree-project! a3))
  (if (and result-path (memq (prompt-kind p) '(file dir)))
      (let ([line (tree-line-of (app-tree a4) result-path)])
        (if line (tree-goto a4 line) a4))
      a4))

(define (prompt-cancel a)
  (tree-project! (prompt-clear a)))

;;; ---------- 输入 ----------

(define (plain? k)
  (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))

;; 提示态：回车确认 / Esc 取消 / 其余都交给文档编辑（用户就地在提示行输入）。
(define (prompt-input a k)
  (cond
    [(and (plain? k) (eq? (key-name k) 'escape)) (prompt-cancel a)]
    [(and (plain? k) (eq? (key-name k) 'enter)) (prompt-confirm a)]
    [else (tree-edit a k)]))

;; 把输入当作对树文档的编辑（文本 / 退格 / 方向）。
(define (tree-edit a k)
  (define n (key-name k))
  (cond
    [(and (plain? k) (char? n)) (tree-do a (lambda (e v) (editor-view-insert e v (string n))))]
    [(and (plain? k) (eq? n 'backspace)) (tree-do a (lambda (e v) (editor-view-backspace e v 'backspace)))]
    [(and (plain? k) (eq? n 'del)) (tree-do a (lambda (e v) (editor-view-delete e v 'delete)))]
    [(and (plain? k) (eq? n 'left)) (tree-do a (lambda (e v) (editor-view-left e v)))]
    [(and (plain? k) (eq? n 'right)) (tree-do a (lambda (e v) (editor-view-right e v)))]
    [(and (plain? k) (eq? n 'up)) (tree-do a (lambda (e v) (editor-view-up e v)))]
    [(and (plain? k) (eq? n 'down)) (tree-do a (lambda (e v) (editor-view-down e v)))]
    [else a]))

;; 展开 / 收起目录并重画。
(define (tree-toggle! a e)
  (define t (app-tree a))
  (cond
    [(not (entry-dir? e)) a]
    [(hash-has-key? (tree-expanded t) (entry-path e))
     (tree-project! (struct-copy app a [tree (struct-copy tree t [expanded (hash-remove (tree-expanded t) (entry-path e))])]))]
    [else
     (define children (hash-set (tree-children t) (entry-path e)
                                (or (hash-ref (tree-children t) (entry-path e) #f)
                                    (list-dir (entry-path e)))))
     (tree-project!
      (struct-copy app a
        [tree (struct-copy tree t [children children]
                           [expanded (hash-set (tree-expanded t) (entry-path e) #t)])]))]))

;; 激活光标处：目录展开/收起，文件打开。
(define (tree-activate a)
  (define e (tree-cur-entry a))
  (cond
    [(not e) a]
    [(entry-dir? e) (tree-toggle! a e)]
    [else (app-open a (entry-path e))]))

(define (tree-delete a)
  (define e (tree-cur-entry a))
  (cond
    [(not e) a]
    [(equal? (entry-path e) (entry-path (tree-root (app-tree a)))) a]  ; 根目录禁删
    [else (prompt-start a 'delete
                        (format "删除~a ~a？(y/n) "
                                (if (entry-dir? e) "目录" "文件") (entry-name e))
                        (entry-path e))]))

(define (tree-key a k)
  (define n (key-name k))
  (cond
    [(and (plain? k) (eq? n 'up)) (tree-do a (lambda (e v) (editor-view-up e v)))]
    [(and (plain? k) (eq? n 'down)) (tree-do a (lambda (e v) (editor-view-down e v)))]
    [(and (plain? k) (eq? n 'left)) (tree-do a (lambda (e v) (editor-view-left e v)))]
    [(and (plain? k) (eq? n 'right)) (tree-do a (lambda (e v) (editor-view-right e v)))]
    [(and (plain? k) (eq? n 'enter)) (tree-activate a)]
    [(and (plain? k) (char? n) (char=? n #\n)) (prompt-start a 'file "新建文件: " (tree-target-dir a))]
    [(and (plain? k) (char? n) (char=? n #\m)) (prompt-start a 'dir "新建目录: " (tree-target-dir a))]
    [(and (plain? k) (char? n) (char=? n #\d)) (tree-delete a)]
    [else a]))

;; 树是自洽文档：提示态优先（文本直接进文档），否则自己的键。
(define (tree-input a in)
  (cond
    [(prompt-active? (app-tree a))
     (cond [(text? in) (tree-do a (lambda (e v) (editor-view-insert e v (text-s in))))]
           [(key? in) (prompt-input a in)]
           [else a])]
    [(key? in) (tree-key a in)]
    [else a]))

;;; ---------- 工具 ----------

(define (unique-name dir name)
  (define names (for/list ([e (in-list (fs-list dir))]) (entry-name e)))
  (if (not (member name names))
      name
      (let loop ([i 2])
        (define cand (format "~a-~a" name i))
        (if (member cand names) (loop (add1 i)) cand))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define d (make-temporary-file "rbtree-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\n" f #:exists 'replace)
  (make-directory (build-path d "sub"))

  (define ed0 (editor-open "" 10 5 #:line-numbers? #t))
  (define-values (ed1 _did tvid) (editor-add-document-view ed0 "" 30 5 "*tree*" #:line-numbers? #f))
  (define a0 (tree-project! (app ed1 (hash) (tree-open d) tvid 2 0 0 6 40)))
  (check-equal? (editor-view-string (app-editor a0) tvid)
                (string-append "▾ " (path->string d) "\n  ▸ sub\n    a.txt"))

  ;; 光标到 a.txt 行（根 0，sub 1，a 2）
  (define a1 (tree-goto a0 2))
  (check-equal? (entry-name (tree-cur-entry a1)) "a.txt")

  ;; 提示行：新建文件 → 用户往文档里敲 → 读值 → 清理
  (define a2 (prompt-start a1 'file "新建文件: " d))
  (check-true (prompt-active? (app-tree a2)))
  (define a3 (tree-input a2 (key #\x #f #f #f #f)))
  (define a4 (tree-input a3 (key #\y #f #f #f #f)))
  (check-equal? (prompt-value a4) "xy")
  (define a5 (prompt-confirm a4))
  (check-false (prompt-active? (app-tree a5)))
  (check-true (file-exists? (build-path d "xy")))
  ;; 提示行已被清理（文档里没有 "新建文件"）
  (check-false (regexp-match? #rx"新建文件" (editor-view-string (app-editor a5) tvid)))

  (delete-directory/files d)
  (displayln "lab-rebuild/tree.rkt: all tests passed"))
