#lang racket

;;; ============================================================================
;;; tree.rkt —— 文件树组件：一个普通文档 + 文件交互
;;; ============================================================================
;;;
;;; 规则只有一条：**一行一项**。可见节点按展开状态深度优先排成行，第 i 项 ↔ 第 i 行。
;;; 树没有专门的"选中"状态 —— 选中就是 core 文档里的光标行。
;;;
;;; 投影（tree-sync）把可见节点整份重建为一个普通 core 文档；face 只是高亮格。
;;; 输入（tree-input）只改树自己的状态 / 发 effect，不改全局结构。
;;;
;;; 提示行（建 / 删）也是**派生行**：文本 = label ⊕ value，value 存在树状态里，
;;; 所以整份投影永远可由状态重建，不会抹掉用户输入。
;;;
;;; 缩进只表示层次：根与其一级子项同列（根是橙色标题），二级起每层 2 格。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "host.rkt"
         "io.rkt"
         "fs.rkt")

(provide (struct-out tree)
         tree-open tree-lines tree-entry-at
         tree-sync tree-input tree-pointer)

;;; ---------- 状态 ----------

(struct tree (root expanded children prompt goto) #:transparent)
;; root     : entry（目录；name 是绝对路径）
;; expanded : hash（dir-path → #t）
;; children : hash（dir-path → (listof entry)）
;; prompt   : #f | (prompt kind label value target)
;; goto     : #f | path —— 投影后光标落到的行（建/删后定位；投影时消费掉）

(struct prompt (kind label value target) #:transparent)
;; kind : 'file | 'dir | 'delete
;; target : file/dir → 目标目录 path；delete → 要删的 path

(define (tree-open root)
  (define r (canon (if (path? root) root (string->path root))))
  (define e (entry (path->string r) r #t))
  (tree e (hash r #t) (hash r (entries r)) #f #f))

;;; ---------- 可见节点（一行一项） ----------

(define (visible st)
  (define (walk e d)
    (cons (cons d e)
          (if (and (entry-dir? e) (hash-has-key? (tree-expanded st) (entry-path e)))
              (append* (for/list ([c (in-list (hash-ref (tree-children st) (entry-path e) '()))])
                         (walk c (add1 d))))
              '())))
  (walk (tree-root st) 0))

(define (structure-line d.e)
  (string-append (make-string (* 2 (max 0 (sub1 (car d.e)))) #\space) (entry-name (cdr d.e))))

(define (structure-lines st) (for/list ([x (in-list (visible st))]) (structure-line x)))

;; 文件模式结构行（对外名，测试用）。
(define (tree-lines st) (structure-lines st))

(define (line-face opened e)
  (cond [(entry-dir? e) 'tree-dir]
        [(hash-has-key? opened (entry-path e)) 'tree-open]
        [else 'tree-file]))

(define (struct-face opened d.e)
  (if (zero? (car d.e)) 'tree-root (line-face opened (cdr d.e))))

(define (tree-entry-at st line)
  (define vis (visible st))
  (and (>= line 0) (< line (length vis)) (cdr (list-ref vis line))))

(define (tree-line-of st path)
  (for/first ([x (in-list (visible st))] [i (in-naturals)]
              #:when (equal? (entry-path (cdr x)) path)) i))

;;; ---------- 投影 ----------

(define (pad-to s w)
  (if (>= (string-length s) w) s (string-append s (make-string (- w (string-length s)) #\space))))

(define (prompt-line st)
  (define p (tree-prompt st))
  (and p (string-append (prompt-label p) (prompt-value p))))

;; → (values document tree' cursor)
(define (tree-sync ctx st)
  (define structs (structure-lines st))
  (define faces (for/list ([x (in-list (visible st))]) (struct-face (ctx-opened ctx) x)))
  (define in (prompt-line st))
  (define raw (if in (append structs (list in)) structs))
  (define w (for/fold ([m (ctx-pane-w ctx)]) ([l (in-list raw)]) (max m (string-length l))))
  (define ls (for/list ([l (in-list raw)]) (pad-to l w)))
  (define doc0 (document-open (if (null? ls) "" (string-join ls "\n"))))
  (define doc
    (for/fold ([d doc0]) ([face (in-list faces)] [i (in-naturals)])
      (document-highlight-fill d i 0 i (string-length (list-ref ls i)) face)))
  (define doc* (if in
                   (document-highlight-fill doc (sub1 (length ls)) 0 (sub1 (length ls))
                                            (string-length (last ls)) 'tree-prompt)
                   doc))
  (define cur
    (cond
      [in
       (define line (sub1 (length ls)))
       (define h (max 1 (ctx-pane-h ctx)))
       (editor-view-set-top-line! (ctx-editor ctx) (ctx-vid ctx) (max 0 (- line (sub1 h))))
       (point line (string-length in))]
      [(tree-goto st) (define line (tree-line-of st (tree-goto st))) (and line (point line 0))]
      [else #f]))
  (values doc* (struct-copy tree st [goto #f]) cur))

;;; ---------- 输入 ----------

(define (cursor-line ctx) (editor-view-point-line (ctx-editor ctx) (ctx-vid ctx)))

(define (core! ctx f) (f (ctx-editor ctx) (ctx-vid ctx)))

(define (target-dir ctx st)
  (define e (tree-entry-at st (cursor-line ctx)))
  (define root (entry-path (tree-root st)))
  (cond
    [(not e) root]
    [(entry-dir? e) (entry-path e)]
    [else (canon (let-values ([(base _n _d) (split-path (entry-path e))]) base))]))

;; 提示行里只认输入 / 退格 / 回车 / Esc；不把字符写进文档。
(define (prompt-key ctx st k)
  (define n (key-name k))
  (cond
    [(and (plain-key? k) (eq? n 'escape)) (values (struct-copy tree st [prompt #f]) '())]
    [(and (plain-key? k) (eq? n 'enter)) (prompt-confirm ctx st)]
    [(and (plain-key? k) (eq? n 'backspace))
     (define v (prompt-value (tree-prompt st)))
     (values (struct-copy tree st
               [prompt (struct-copy prompt (tree-prompt st)
                         [value (if (string=? v "") "" (substring v 0 (sub1 (string-length v))))])])
             '())]
    [else (values st '())]))

(define (prompt-confirm ctx st)
  (define p (tree-prompt st))
  (define val (prompt-value p))
  (define result
    (case (prompt-kind p)
      [(file) (and (not (string=? val "")) (create-file! (build-path (prompt-target p) (unique-name (prompt-target p) val))))]
      [(dir)  (and (not (string=? val "")) (make-dir! (build-path (prompt-target p) (unique-name (prompt-target p) val))))]
      [(delete) (and (string-ci=? val "y") (delete! (prompt-target p)) (prompt-target p))]
      [else #f]))
  (define refresh (case (prompt-kind p)
                    [(file dir) (prompt-target p)]
                    [(delete) (and result (canon (let-values ([(base _n _d) (split-path result)]) base)))]
                    [else #f]))
  (define st1 (struct-copy tree st [prompt #f]))
  (define st2 (if refresh
                  (struct-copy tree st1 [children (hash-set (tree-children st1) refresh (entries refresh))])
                  st1))
  (define st3 (if (and result (memq (prompt-kind p) '(file dir)))
                  (struct-copy tree st2 [goto result])
                  st2))
  ;; 删除的若正被打开 → 通知 host 关文档（effect 里带上 did）。
  (define did (and (eq? (prompt-kind p) 'delete) result
                   (for/first ([(path d) (in-hash (ctx-opened ctx))] #:when (equal? path result)) d)))
  (values st3 (if did (list (list 'close-document did)) '())))

(define (prompt-start st kind label target)
  (struct-copy tree st [prompt (prompt kind label "" target)] [goto #f]))

(define (toggle! st e)
  (define dir (entry-path e))
  (cond
    [(not (entry-dir? e)) st]
    [(hash-has-key? (tree-expanded st) dir)
     (struct-copy tree st [expanded (hash-remove (tree-expanded st) dir)])]
    [else
     (struct-copy tree st
       [children (hash-set (tree-children st) dir (entries dir))]
       [expanded (hash-set (tree-expanded st) dir #t)])]))

;; → (values tree' effects)
(define (tree-input ctx st in)
  (cond
    [(tree-prompt st)
     (cond
       [(text? in)
        (values (struct-copy tree st
                  [prompt (struct-copy prompt (tree-prompt st)
                            [value (string-append (prompt-value (tree-prompt st)) (text-s in))])])
                '())]
       [(key? in)
        (cond
          [(and (plain-key? in) (char? (key-name in)))
           (values (struct-copy tree st
                     [prompt (struct-copy prompt (tree-prompt st)
                               [value (string-append (prompt-value (tree-prompt st)) (string (key-name in)))])])
                   '())]
          [else (prompt-key ctx st in)])]
       [else (values st '())])]
    [(key? in)
     (define n (key-name in))
     (define e (tree-entry-at st (cursor-line ctx)))
     (cond
       [(and (plain-key? in) (eq? n 'up)) (core! ctx (lambda (ed vid) (editor-view-up! ed vid))) (values st '())]
       [(and (plain-key? in) (eq? n 'down)) (core! ctx (lambda (ed vid) (editor-view-down! ed vid))) (values st '())]
       [(and (plain-key? in) (eq? n 'left)) (core! ctx (lambda (ed vid) (editor-view-left! ed vid))) (values st '())]
       [(and (plain-key? in) (eq? n 'right)) (core! ctx (lambda (ed vid) (editor-view-right! ed vid))) (values st '())]
       [(and (plain-key? in) (eq? n 'enter))
        (cond
          [(not e) (values st '())]
          [(entry-dir? e) (values (toggle! st e) '())]
          [else (values st (list (list 'open (entry-path e))))])]
       [(and (plain-key? in) (char? n) (char=? n #\n)) (values (prompt-start st 'file "新建文件: " (target-dir ctx st)) '())]
       [(and (plain-key? in) (char? n) (char=? n #\m)) (values (prompt-start st 'dir "新建目录: " (target-dir ctx st)) '())]
       [(and (plain-key? in) (char? n) (char=? n #\d))
        (cond
          [(not e) (values st '())]
          [(equal? (entry-path e) (entry-path (tree-root st))) (values st '())]
          [else (values (prompt-start st 'delete
                                      (format "删除~a ~a？(y/n) " (if (entry-dir? e) "目录" "文件") (entry-name e))
                                      (entry-path e))
                        '())])]
       [else (values st '())])]
    [else (values st '())]))

(define (tree-pointer ctx st in lr lc)
  (cond
    [(wheel? in)
     (core! ctx (lambda (ed vid) (editor-view-scroll! ed vid (if (eq? (wheel-direction in) 'up) -3 3))))
     (values st '())]
    [(mouse? in)
     (define-values (line _col) (editor-view-screen-pos->point (ctx-editor ctx) (ctx-vid ctx) lr lc))
     (cond
       [(and line (memq (mouse-kind in) '(press drag)))
        (core! ctx (lambda (ed vid) (editor-view-set-point! ed vid (point line 0))))
        (values st '())]
       [else (values st '())])]
    [else (values st '())]))

;;; ---------- 工具 ----------

(define (unique-name dir name)
  (define names (for/list ([e (in-list (entries dir))]) (entry-name e)))
  (if (not (member name names))
      name
      (let loop ([i 2])
        (define cand (format "~a-~a" name i))
        (if (member cand names) (loop (add1 i)) cand))))

;;; ============================================================================
;;; 测试（直接喂 ctx，树不依赖 app）
;;; ============================================================================

(module+ test
  (require rackunit)

  (define d (make-temporary-file "rbtree-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\n" f #:exists 'replace)
  (make-directory (build-path d "sub"))

  (define ed (editor-open "" 10 6 #:line-numbers? #f))
  (define (ctx0 #:opened [opened (hash)])
    (ctx 0 0 10 6 ed 0 opened))
  (define (run ctx st)
    (define-values (doc st* cur) (tree-sync ctx st))
    (editor-view-assign! ed 0 doc)
    (when cur (editor-view-set-point! ed 0 cur))
    st*)
  (define (feed ctx st in)
    (define-values (st* _e) (tree-input ctx st in))
    (run ctx st*))
  (define (k name) (key name modifiers-none))
  (define (doc-str) (editor-view-string ed 0))

  (define C (ctx0))
  (define st0 (run C (tree-open d)))
  (check-equal? (tree-lines (tree-open d)) (list (path->string d) "sub" "a.txt"))
  (check-eq? (document-highlight-at (editor-view-document ed 0) 0 0) 'tree-root)
  (check-eq? (document-highlight-at (editor-view-document ed 0) 1 0) 'tree-dir)
  (define st0b (run (ctx0 #:opened (hash f 1)) (tree-open d)))
  (check-eq? (document-highlight-at (editor-view-document ed 0) 2 0) 'tree-open)

  ;; open 文件 = effect
  (define stF (feed C st0 (k 'down)))
  (define stF2 (feed C stF (k 'down)))
  (define-values (_ eff) (tree-input C stF2 (k 'enter)))
  (check-equal? eff (list (list 'open f)))

  ;; 新建文件：n → 手敲 → 回车
  (define st1 (feed C (run C (tree-open d)) (k #\n)))
  (check-true (regexp-match? #rx"新建文件" (doc-str)))
  (define st2 (feed C st1 (k #\x)))
  (define st3 (feed C st2 (k #\y)))
  (check-true (regexp-match? #rx"新建文件: xy" (doc-str)))
  (define st4 (feed C st3 (k 'backspace)))
  (check-true (regexp-match? #rx"新建文件: x" (doc-str)))
  (define st5 (feed C st3 (k 'enter)))
  (check-true (file-exists? (build-path d "xy")))
  (check-false (regexp-match? #rx"新建文件" (doc-str)))

  ;; 删除
  (define xy (build-path d "xy"))
  (editor-view-set-point! ed 0 (point (tree-line-of st5 xy) 0))
  (define st6 (feed C st5 (k #\d)))
  (define st7 (feed C st6 (k #\y)))
  (define st8 (feed C st7 (k 'enter)))
  (check-false (file-exists? xy))

  (delete-directory/files d)
  (displayln "lab-rebuild/tree.rkt: all tests passed"))
