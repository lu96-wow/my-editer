#lang racket

(require "../core/text/document.rkt"
         "fs.rkt")

;;; tree.rkt —— 文件树组件（就是一个普通文档）
;;;
;;; **没有专门的"选中"状态**:选中 = 光标所在行。导航 / 滚动 / 光标全走 core
;;; （editor-view-up/down、view-ensure），树不自己维护 selected、也没有固定视角。
;;; 组件只把「可见节点」投影成一份文档；动作由 app 从**光标行**取 entry 再调。
;;;
;;; 读 / 写文件系统都走注入的 fs（fs.rkt），测试可换内存实现。
;;; tree-sync 只从缓存投影（纯函数）；IO 只在展开 / 建 / 删时发生。
;;;
;;; face：'tree-dir / 'tree-file / 'tree-open（选中是 core 的光标，不再用 face 画）。

(provide
 ;; ---------- 类型 ----------
 (struct-out tree)

 ;; ---------- 构造 / 数据 ----------
 tree-open
 tree-set-open-paths

 ;; ---------- 行 → 节点 / 展开 ----------
 tree-line-entry
 tree-toggle

 ;; ---------- 动作（entry 从光标行取） ----------
 tree-activate                     ; st × entry → (values st intent)，intent = (list 'open path) | #f
 tree-target-dir                   ; st × entry → path（新建落点）
 tree-create                       ; st × entry × kind × name → (values st path)
 tree-delete                       ; st × entry → (values st path | #f)

 ;; ---------- 投影 ----------
 tree-sync)

;;; ---------- 数据 ----------

(struct tree (root fs children expanded visible open-paths) #:transparent)
;; root       : entry（目录，name 是绝对路径）
;; fs         : fs
;; children   : hash path → (listof entry)   ; 缓存
;; expanded   : hash path → #t
;; visible    : (listof (cons depth entry))  ; 最近一次投影的可见行（行→节点）
;; open-paths : hash path → #t

;;; ---------- 构造 / 数据 ----------

(define (list-dir fs dir)
  (sort ((fs-list fs) dir)
        (lambda (a b)
          (cond [(and (entry-dir? a) (not (entry-dir? b))) #t]
                [(and (entry-dir? b) (not (entry-dir? a))) #f]
                [else (string<? (entry-name a) (entry-name b))]))))

(define (tree-open root fs)
  (define root* (canon-path (if (path? root) root (string->path root))))
  (define r (entry (path->string root*) root* #t))     ; 根显示绝对路径
  (tree r fs (hash root* (list-dir fs root*)) (hash root* #t) '() (hash)))

(define (tree-set-open-paths st paths)
  (struct-copy tree st [open-paths (for/hash ([p (in-list paths)]) (values p #t))]))

(define (tree-reload st dir)
  (struct-copy tree st
    [children (hash-set (tree-children st) dir (list-dir (tree-fs st) dir))]
    [expanded (hash-set (tree-expanded st) dir #t)]))

;;; ---------- 行 → 节点 / 展开 ----------

(define (visible-of st)
  (define (walk e depth)
    (cons (cons depth e)
          (if (and (entry-dir? e) (hash-has-key? (tree-expanded st) (entry-path e)))
              (append* (for/list ([k (in-list (hash-ref (tree-children st) (entry-path e)))])
                         (walk k (add1 depth))))
              '())))
  (walk (tree-root st) 0))

(define (tree-line-entry st line)
  (define vis (tree-visible st))
  (and (>= line 0) (< line (length vis)) (cdr (list-ref vis line))))

(define (tree-toggle st e)
  (cond
    [(not (entry-dir? e)) st]
    [(hash-has-key? (tree-expanded st) (entry-path e))
     (struct-copy tree st [expanded (hash-remove (tree-expanded st) (entry-path e))])]
    [else
     (struct-copy tree st
       [children (hash-set (tree-children st) (entry-path e)
                           (or (hash-ref (tree-children st) (entry-path e) #f)
                               (list-dir (tree-fs st) (entry-path e))))]
       [expanded (hash-set (tree-expanded st) (entry-path e) #t)])]))

;;; ---------- 动作 ----------

(define (tree-activate st e)
  (cond
    [(not e) (values st #f)]
    [(entry-dir? e) (values (tree-toggle st e) #f)]
    [else (values st (list 'open (entry-path e)))]))

;; 新建落点：目录 → 本身；文件 → 父目录；无 entry → root。
(define (tree-target-dir st e)
  (cond
    [(not e) (entry-path (tree-root st))]
    [(entry-dir? e) (entry-path e)]
    [else (canon-path (let-values ([(base _n _d) (split-path (entry-path e))]) base))]))

(define (bump-name name i)
  (define dot (for/last ([j (in-range (string-length name))]
                         #:when (char=? (string-ref name j) #\.)) j))
  (if (and dot (> dot 0))
      (string-append (substring name 0 dot) (format "-~a" i) (substring name dot))
      (format "~a-~a" name i)))

(define (unique-name fs dir name)
  (define names (for/list ([e (in-list (list-dir fs dir))]) (entry-name e)))
  (if (not (member name names))
      name
      (let loop ([i 2])
        (define cand (bump-name name i))
        (if (member cand names) (loop (add1 i)) cand))))

;; kind : 'file | 'dir
(define (tree-create st e kind name)
  (define fs (tree-fs st))
  (define dir (tree-target-dir st e))
  (define path (build-path dir (unique-name fs dir name)))
  (if (eq? kind 'dir) ((fs-mkdir fs) path) ((fs-create fs) path))
  (define st1 (tree-reload st dir))
  (values (struct-copy tree st1 [visible (visible-of st1)]) path))

(define (tree-delete st e)
  (cond
    [(or (not e) (equal? (entry-path e) (entry-path (tree-root st)))) (values st #f)]
    [else
     (define path (entry-path e))
     ((fs-delete (tree-fs st)) path)
     (define parent (canon-path (let-values ([(base _n _d) (split-path path)]) base)))
     (define st1 (tree-reload st parent))
     (values (struct-copy tree st1 [visible (visible-of st1)]) path)]))

;;; ---------- 投影 ----------

(define (render-line st d.e)
  (define e (cdr d.e))
  (string-append (make-string (* 2 (car d.e)) #\space)
                 (if (entry-dir? e)
                     (if (hash-has-key? (tree-expanded st) (entry-path e)) "▾ " "▸ ")
                     "  ")
                 (entry-name e)))

(define (line-face st e)
  (cond [(entry-dir? e) 'tree-dir]
        [(hash-has-key? (tree-open-paths st) (entry-path e)) 'tree-open]
        [else 'tree-file]))

(define (tree-doc st)
  (define vis (tree-visible st))
  (define lines (for/list ([d.e (in-list vis)]) (render-line st d.e)))
  (define txt (if (null? lines) "" (string-join lines "\n")))
  (for/fold ([doc (document-open txt)]) ([d.e (in-list vis)] [i (in-naturals)])
    (document-highlight-fill doc i 0 i (string-length (list-ref lines i))
                             (line-face st (cdr d.e)))))

(define (tree-sync _ctx st)
  (define st* (struct-copy tree st [visible (visible-of st)]))
  (values (tree-doc st*) st*))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define (mem)
    (fs-memory (list (cons "/r" 'dir) (cons "/r/a" 'dir) (cons "/r/a/c.txt" 'file)
                     (cons "/r/b.txt" 'file))))
  (define R (string->path "/r"))
  (define (ps p) (path->string p))
  (define (synced st) (let-values ([(d s) (tree-sync #f st)]) s))
  (define (entry-at st line) (tree-line-entry st line))

  (define st0 (tree-open R (mem)))
  (define-values (doc st1) (tree-sync #f st0))
  (check-equal? (document->string doc) "▾ /r\n  ▸ a\n    b.txt")
  (check-eq? (document-highlight-at doc 0 2) 'tree-dir)
  (check-eq? (document-highlight-at doc 2 2) 'tree-file)

  ;; 展开 a（root0 / a1 / c2 / b3）
  (define st2 (tree-toggle st1 (entry-at st1 1)))
  (define-values (doc2 st3) (tree-sync #f st2))
  (check-equal? (document->string doc2) "▾ /r\n  ▾ a\n      c.txt\n    b.txt")

  ;; 行 → 节点；activate → intent
  (check-equal? (ps (entry-path (entry-at st3 2))) "/r/a/c.txt")
  (define-values (st4 intent) (tree-activate st3 (entry-at st3 2)))
  (check-equal? intent (list 'open (string->path "/r/a/c.txt")))

  ;; 已打开高亮
  (define st6 (tree-set-open-paths st3 (list (string->path "/r/a/c.txt"))))
  (define-values (doc6 _) (tree-sync #f st6))
  (check-eq? (document-highlight-at doc6 2 4) 'tree-open)

  ;; ---------- 建 / 删 ----------
  (define F (mem))
  (define b0 (synced (tree-open R F)))
  (define a-entry (entry-at b0 1))                         ; a（目录）
  (define-values (b1 p1) (tree-create b0 a-entry 'file "n.txt"))
  (check-equal? (ps p1) "/r/a/n.txt")
  (check-not-false (member (string->path "/r/a/n.txt") (map entry-path ((fs-list F) (string->path "/r/a")))))
  ;; 重名 → n-2.txt
  (define-values (_b2 p2) (tree-create b0 a-entry 'file "n.txt"))
  (check-equal? (ps p2) "/r/a/n-2.txt")
  ;; 建目录
  (define-values (_b3 p3) (tree-create b0 a-entry 'dir "sub"))
  (check-equal? (ps p3) "/r/a/sub")

  ;; 删 b.txt
  (define c0 (synced (tree-open R (mem))))
  (define-values (c1 pdel) (tree-delete c0 (entry-at c0 2)))
  (check-equal? (ps pdel) "/r/b.txt")
  (check-false (member (string->path "/r/b.txt") (map entry-path ((fs-list (tree-fs c1)) (string->path "/r")))))
  ;; 删根 → no-op
  (define-values (c2 p4) (tree-delete c1 (entry-at c1 0)))
  (check-false p4)
  (check-equal? c2 c1)

  (displayln "lab/tree.rkt: all tests passed"))
