#lang racket

;;; ============================================================================
;;; tree.rkt —— 文件树：一个普通文档 + 文档管理 + 焦点
;;; ============================================================================
;;;
;;; 树同时是「一个普通文档」和「中枢」（开/关文件）。这里讲它的**投影**和**输入**。
;;;
;;; ── 结构 / 输入分开，投影时合并 ────────────────────────────────────────────
;;;   结构   tree-structure-lines : state → (listof string)   列表行
;;;   输入   tree-input-line      : state → string | #f       提示行（只读标签）
;;;   文档   tree-document-lines  = 结构行 ++ (可选)输入行
;;;
;;; **投影 tree-project! 永远整份重建**（不再"事后往文档里插一行"），所以结构
;;; 变化后文档总是对的。输入行的值由用户就地敲进文档，不在 state 里，也不会被
;;; 重建冲掉 —— 因为输入期间不做结构变化，也就不会重建。
;;;
;;; ── 输入行钉在最下面一行 ──────────────────────────────────────────────────
;;; 输入行是文档最后一行。树知道自己的高度（app-pane-height），投影时把视口顶到
;;; "最后一行刚好在可见区最下面"，于是它看起来就是树最下面一行。
;;;
;;; ── 光标 ↔ 节点 ──────────────────────────────────────────────────────────
;;; 只有结构行对应节点；光标在输入行上时 tree-line-entry 返回 #f。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/range.rkt"
         "app.rkt"
         "layout.rkt"
         "fs.rkt"
         "input.rkt")

(provide (struct-out tree)
         tree-open tree-project! tree-input tree-pointer
         tree-lines)                     ; 结构行（供观察/测试）

;;; ---------- 私有状态 ----------

(struct tree (root expanded children prompt) #:transparent)
;; root     : entry（目录；name 是绝对路径）
;; expanded : hash（dir-path → #t）
;; children : hash（dir-path → (listof entry)）
;; prompt   : #f | (prompt kind label data)

(struct prompt (kind label data) #:transparent)
;; kind : 'file | 'dir | 'delete
;; label: string（输入行里只读的前缀）
;; data : file/dir → 目标目录 path；delete → 目标 path

(define (ts a pid) (pane-state (app-pane a pid)))
(define (ts-set a pid t) (app-set-pane a pid (struct-copy pane (app-pane a pid) [state t])))

;;; ---------- 结构：目录列表 ----------

(define (list-dir dir)
  (sort (fs-list dir)
        (lambda (x y)
          (cond [(and (entry-dir? x) (not (entry-dir? y))) #t]
                [(and (entry-dir? y) (not (entry-dir? x))) #f]
                [else (string<? (entry-name x) (entry-name y))]))))

(define (tree-open root)
  (define r (canon-path (if (path? root) root (string->path root))))
  (define re (entry (path->string r) r (directory-exists? r)))
  (tree re
        (if (directory-exists? r) (hash r #t) (hash))
        (if (directory-exists? r) (hash r (list-dir r)) (hash))
        #f))

;; 可见节点（按展开状态深度优先）。
(define (visible-of t)
  (define (walk e d)
    (cons (cons d e)
          (if (and (entry-dir? e) (hash-has-key? (tree-expanded t) (entry-path e)))
              (append* (for/list ([k (in-list (hash-ref (tree-children t) (entry-path e) '()))])
                         (walk k (add1 d))))
              '())))
  (walk (tree-root t) 0))

;; 一行结构文本：「缩进 + 标记 + 名字」。
(define (structure-line t d.e)
  (define e (cdr d.e))
  (string-append (make-string (* 2 (car d.e)) #\space)
                 (if (entry-dir? e)
                     (if (hash-has-key? (tree-expanded t) (entry-path e)) "▾ " "▸ ")
                     "  ")
                 (entry-name e)))

;; 结构行（不含输入行）。
(define (tree-structure-lines t)
  (for/list ([d.e (in-list (visible-of t))]) (structure-line t d.e)))

;; 一行的 face：文件夹 / 已打开文件 / 未打开文件。
(define (line-face opened e)
  (cond [(entry-dir? e) 'tree-dir]
        [(hash-has-key? opened (entry-path e)) 'tree-open]
        [else 'tree-file]))

;; 对外名 = 结构行。
(define (tree-lines t) (tree-structure-lines t))

;; 输入行（#f = 没有）。
(define (tree-input-line t)
  (and (tree-prompt t) (prompt-label (tree-prompt t))))

;; 文档 = 结构行 ++ 输入行。
(define (tree-document-lines t)
  (define ls (tree-structure-lines t))
  (define in (tree-input-line t))
  (if in (append ls (list in)) ls))

;; 结构行（不含输入行）的数量 = 输入行的行号。
(define (structure-count t) (length (tree-structure-lines t)))

(define (tree-line-entry t line)
  (define vis (visible-of t))
  (and (>= line 0) (< line (length vis)) (cdr (list-ref vis line))))

(define (tree-line-of t path)
  (for/first ([v (in-list (visible-of t))] [i (in-naturals)]
              #:when (equal? (entry-path (cdr v)) path)) i))

;;; ---------- 投影 ----------

(define (tv a pid) (app-pane-vid a pid))

;; 整份重建：结构行（按类型上 face）+ 输入行；输入行钉到可见区最下面一行。
(define (tree-project! a pid)
  (define t (ts a pid))
  (define vis (visible-of t))
  (define opened (app-opened a))
  (define struct-lines (for/list ([d.e (in-list vis)]) (structure-line t d.e)))
  (define in (tree-input-line t))
  (define ls (if in (append struct-lines (list in)) struct-lines))
  (define doc0 (document-open (if (null? ls) "" (string-join ls "\n"))))
  ;; 结构行按类型上色；输入行用 'tree-prompt。
  (define doc
    (for/fold ([d doc0]) ([d.e (in-list vis)] [i (in-naturals)])
      (document-highlight-fill d i 0 i (string-length (list-ref ls i))
                               (line-face opened (cdr d.e)))))
  (define doc* (if in
                   (document-highlight-fill doc (sub1 (length ls)) 0 (sub1 (length ls))
                                            (string-length in) 'tree-prompt)
                   doc))
  (define a1 (struct-copy app a [editor (editor-view-assign (app-editor a) (tv a pid) doc*)]))
  (cond
    [(not in) a1]
    [else
     ;; 输入行 = 最后一行；光标放到标签后；视口顶到让最后一行恰在可见区底。
     (define vid (tv a1 pid))
     (define line (sub1 (length ls)))
     (define h (max 1 (app-pane-height a1 pid)))
     (define ed1 (editor-view-set-point (app-editor a1) vid (point line (string-length in))))
     (define top (max 0 (- line (sub1 h))))
     (define ed2 (editor-view-set-top-line ed1 vid top))
     (struct-copy app a1 [editor ed2])]))

;;; ---------- 光标处 ----------

(define (tree-cursor-line a pid)
  (editor-view-point-line (app-editor a) (tv a pid)))

(define (tree-cur-entry a pid)
  (tree-line-entry (ts a pid) (tree-cursor-line a pid)))

(define (tree-target-dir a pid)
  (define e (tree-cur-entry a pid))
  (define root (entry-path (tree-root (ts a pid))))
  (cond
    [(not e) root]
    [(entry-dir? e) (entry-path e)]
    [else (canon-path (let-values ([(base _n _d) (split-path (entry-path e))]) base))]))

(define (tree-do a pid f)
  (define ed (app-editor a))
  (define ed* (call-with-values (lambda () (f ed (tv a pid))) (lambda (v . _) v)))
  (struct-copy app a [editor ed*]))

(define (tree-goto a pid line)
  (tree-do a pid (lambda (e v) (editor-view-set-point e v (point line 0)))))

;;; ---------- 输入（提示行） ----------

(define (prompt-active? t) (and (tree-prompt t) #t))

(define (prompt-value a pid)
  (define p (tree-prompt (ts a pid)))
  (define lines (string-split (editor-view-string (app-editor a) (tv a pid)) "\n" #:trim? #f))
  (define ln (last lines))
  (substring ln (min (string-length ln) (string-length (prompt-label p)))))

;; 开始输入：写 state 的 prompt → 投影（自动带出输入行并钉底）→ 把标签设为只读。
(define (prompt-start a pid kind label data)
  (define a1 (ts-set a pid (struct-copy tree (ts a pid) [prompt (prompt kind label data)])))
  (define a2 (tree-project! a1 pid))
  (define vid (tv a2 pid))
  (define line (structure-count (ts a2 pid)))
  (define ed (editor-view-readonly-range (app-editor a2) vid
              (range-of (point line 0) (point line (string-length label))) #t))
  (struct-copy app a2 [editor ed]))

(define (prompt-clear a pid)
  (ts-set a pid (struct-copy tree (ts a pid) [prompt #f])))

;; 读值 → 执行 → 刷新目录 → 重建（清掉输入行）。
(define (prompt-confirm a pid)
  (define p (tree-prompt (ts a pid)))
  (define val (prompt-value a pid))
  (define a1 (prompt-clear a pid))
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
  ;; **刷新被改动的目录**：新建刷目标目录；删除刷它**父目录**（而不是被删的路径）。
  (define refresh-dir
    (case (prompt-kind p)
      [(file dir) (prompt-data p)]
      [(delete) (and result-path
                     (canon-path (let-values ([(base _n _d) (split-path result-path)]) base)))]
      [else #f]))
  (define a3
    (if refresh-dir
        (ts-set a2 pid (struct-copy tree (ts a2 pid)
                         [children (hash-set (tree-children (ts a2 pid))
                                             refresh-dir (list-dir refresh-dir))]))
        a2))
  (define a4 (tree-project! a3 pid))
  (if (and result-path (memq (prompt-kind p) '(file dir)))
      (let ([line (tree-line-of (ts a4 pid) result-path)])
        (if line (tree-goto a4 pid line) a4))
      a4))

(define (prompt-cancel a pid)
  (tree-project! (prompt-clear a pid) pid))

;;; ---------- 输入分发 ----------

(define (plain? k)
  (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))

(define (prompt-input a pid k)
  (cond
    [(and (plain? k) (eq? (key-name k) 'escape)) (prompt-cancel a pid)]
    [(and (plain? k) (eq? (key-name k) 'enter)) (prompt-confirm a pid)]
    [else (tree-edit a pid k)]))

(define (tree-edit a pid k)
  (define n (key-name k))
  (cond
    [(and (plain? k) (char? n)) (tree-do a pid (lambda (e v) (editor-view-insert e v (string n))))]
    [(and (plain? k) (eq? n 'backspace)) (tree-do a pid (lambda (e v) (editor-view-backspace e v 'backspace)))]
    [(and (plain? k) (eq? n 'del)) (tree-do a pid (lambda (e v) (editor-view-delete e v 'delete)))]
    [(and (plain? k) (eq? n 'left)) (tree-do a pid (lambda (e v) (editor-view-left e v)))]
    [(and (plain? k) (eq? n 'right)) (tree-do a pid (lambda (e v) (editor-view-right e v)))]
    [(and (plain? k) (eq? n 'up)) (tree-do a pid (lambda (e v) (editor-view-up e v)))]
    [(and (plain? k) (eq? n 'down)) (tree-do a pid (lambda (e v) (editor-view-down e v)))]
    [else a]))

(define (tree-toggle! a pid e)
  (define t (ts a pid))
  (define dir (entry-path e))
  (cond
    [(not (entry-dir? e)) a]
    [(hash-has-key? (tree-expanded t) dir)
     (tree-project! (ts-set a pid (struct-copy tree t [expanded (hash-remove (tree-expanded t) dir)])) pid)]
    [else
     (define children (hash-set (tree-children t) dir
                                (or (hash-ref (tree-children t) dir #f) (list-dir dir))))
     (tree-project!
      (ts-set a pid (struct-copy tree t [children children]
                                 [expanded (hash-set (tree-expanded t) dir #t)]))
      pid)]))

(define (tree-activate a pid)
  (define e (tree-cur-entry a pid))
  (cond
    [(not e) a]
    [(entry-dir? e) (tree-toggle! a pid e)]
    [else (app-open a (entry-path e))]))

(define (tree-delete a pid)
  (define e (tree-cur-entry a pid))
  (cond
    [(not e) a]
    [(equal? (entry-path e) (entry-path (tree-root (ts a pid)))) a]
    [else (prompt-start a pid 'delete
                        (format "删除~a ~a？(y/n) "
                                (if (entry-dir? e) "目录" "文件") (entry-name e))
                        (entry-path e))]))

(define (tree-key a pid k)
  (define n (key-name k))
  (cond
    [(and (plain? k) (eq? n 'up)) (tree-do a pid (lambda (e v) (editor-view-up e v)))]
    [(and (plain? k) (eq? n 'down)) (tree-do a pid (lambda (e v) (editor-view-down e v)))]
    [(and (plain? k) (eq? n 'left)) (tree-do a pid (lambda (e v) (editor-view-left e v)))]
    [(and (plain? k) (eq? n 'right)) (tree-do a pid (lambda (e v) (editor-view-right e v)))]
    [(and (plain? k) (eq? n 'enter)) (tree-activate a pid)]
    [(and (plain? k) (char? n) (char=? n #\n)) (prompt-start a pid 'file "新建文件: " (tree-target-dir a pid))]
    [(and (plain? k) (char? n) (char=? n #\m)) (prompt-start a pid 'dir "新建目录: " (tree-target-dir a pid))]
    [(and (plain? k) (char? n) (char=? n #\d)) (tree-delete a pid)]
    [else a]))

(define (tree-input a pid in)
  (cond
    [(prompt-active? (ts a pid))
     (cond [(text? in) (tree-do a pid (lambda (e v) (editor-view-insert e v (text-s in))))]
           [(key? in) (prompt-input a pid in)]
           [else a])]
    [(key? in) (tree-key a pid in)]
    [else a]))

(define (tree-pointer a pid in lr lc)
  (case (pointer-action in)
    [(scroll) (tree-do a pid (lambda (e v) (editor-view-scroll e v (if (eq? (pointer-button in) 'up) -3 3))))]
    [else
     (define-values (line _col) (editor-view-screen-pos->point (app-editor a) (tv a pid) lr lc))
     (cond
       [(not line) a]
       [(memq (pointer-action in) '(press move)) (tree-goto a pid line)]
       [else a])]))

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

  ;; 用一个高度受控的 pane 建树（高度用于把输入行钉底）
  (define ed0 (editor-open "" 10 5 #:line-numbers? #t))
  (define-values (ed1 _did tvid) (editor-add-document-view ed0 "" 10 5 "*tree*" #:line-numbers? #f))
  (define (mk) (app ed1 (hash) (hash 0 (pane 'tree tvid (tree-open d) #f #f #t))
                    (lpane 0) 0 0 6 40))
  (define a0 (tree-project! (mk) 0))
  (check-equal? (editor-view-string (app-editor a0) tvid)
                (string-append "▾ " (path->string d) "\n  ▸ sub\n    a.txt"))

  ;; face：文件夹 / 未打开文件 / 已打开文件
  (define doc0 (editor-view-document (app-editor a0) tvid))
  (check-eq? (document-highlight-at doc0 1 2) 'tree-dir)      ; sub
  (check-eq? (document-highlight-at doc0 2 4) 'tree-file)     ; a.txt（未打开）
  (define a0b (tree-project! (struct-copy app a0 [opened (hash f 99)]) 0))
  (check-eq? (document-highlight-at (editor-view-document (app-editor a0b) tvid) 2 4) 'tree-open)

  ;; 结构行只有 3 行（输入行不算节点）
  (define a1 (prompt-start a0 0 'file "新建文件: " d))
  (check-equal? (tree-lines (ts a1 0)) (list (string-append "▾ " (path->string d)) "  ▸ sub" "    a.txt"))
  (check-equal? (structure-count (ts a1 0)) 3)
  ;; 文档 = 结构 3 行 + 输入行
  (check-equal? (length (string-split (editor-view-string (app-editor a1) tvid) "\n")) 4)
  (check-equal? (editor-view-point-line (app-editor a1) tvid) 3)      ; 光标在输入行

  ;; 用户就地敲 → 读值 → 清理
  (define a2 (tree-input a1 0 (key #\x #f #f #f #f)))
  (define a3 (tree-input a2 0 (key #\y #f #f #f #f)))
  (check-equal? (prompt-value a3 0) "xy")
  (define a4 (prompt-confirm a3 0))
  (check-true (file-exists? (build-path d "xy")))
  (check-false (regexp-match? #rx"新建文件" (editor-view-string (app-editor a4) tvid)))

  ;; 删除：父目录刷新（列表里不再有）
  (define xy (build-path d "xy"))
  (define a5 (tree-goto a4 0 (tree-line-of (ts a4 0) xy)))
  (define a6 (prompt-start a5 0 'delete "删除文件 xy？(y/n) " xy))
  (define a7 (tree-input a6 0 (key #\y #f #f #f #f)))
  (define a8 (prompt-confirm a7 0))
  (check-false (file-exists? xy))
  (check-false (for/or ([l (in-list (tree-lines (ts a8 0)))]) (string-suffix? l "xy")))
  (check-false (regexp-match? #rx"xy" (editor-view-string (app-editor a8) tvid)))

  (delete-directory/files d)
  (displayln "lab-rebuild/tree.rkt: all tests passed"))
