#lang racket

;;; core/compose/example.rkt —— 使用方示范：自己拼一个多文件编辑器
;;;
;;; 组合层（editor.rkt）只给 compose-edit/undo/redo 三个纯函数，不做任何编辑器假设。
;;; 这里的**多文件状态、侧边栏布局、语法高亮**全是使用方自己拼的。
;;;
;;; 展示「交出去」的三样：
;;;   · 装饰（语法高亮）：编辑拿到 [f,l] 后自己调 document-apply-patches
;;;   · 布局（侧边栏 + 主编辑区）：自己 window->screen + screen-compose
;;;   · 颜色：face 是语义符号，颜色交给后端主题（这里只渲染纯文本）

(require "../api.rkt" "editor.rkt" "../tool/history.rkt"
         racket/list racket/string rackunit)

;; ── 使用方自己的编辑器状态 ────────────────────────────────
;; 多文件：每个文件一个 document + 自己的撤销账本（撤销按文件独立）。
;; 布局：sidebar-open? 开关侧边栏；active 是当前文件索引。
(struct file (doc hist name) #:transparent)
(struct editor (files active sidebar-open?) #:transparent)

(define (open-file name [text ""] [height 24] [width 60])
  (define-values (d _) (document-add-view (document-open text) height width))
  (file d (make-history) name))

(define (make-editor . files)
  (editor (if (null? files) (list (open-file "*scratch*")) files) 0 #t))

(define (current-file e) (list-ref (editor-files e) (editor-active e)))
(define (put-file! e f)
  (struct-copy editor e [files (list-set (editor-files e) (editor-active e) f)]))

;; ── 命令：把 compose-* 接进自己的状态 ─────────────────────

;; 编辑当前文件：拿到 [fl,ll] 后重标高亮（编排是使用方的）
(define (edit! e op)
  (define fv (current-file e))
  (define-values (doc* hist* fl ll) (compose-edit (file-doc fv) (file-hist fv) 0 op))
  (define e* (put-file! e (file doc* hist* (file-name fv))))
  (values (highlight! e* fl ll) fl ll))

(define (undo! e)
  (define fv (current-file e))
  (define-values (doc* hist* fl ll) (compose-undo (file-doc fv) (file-hist fv) 0))
  (define e* (put-file! e (file doc* hist* (file-name fv))))
  (values (highlight! e* fl ll) fl ll))

(define (redo! e)
  (define fv (current-file e))
  (define-values (doc* hist* fl ll) (compose-redo (file-doc fv) (file-hist fv) 0))
  (define e* (put-file! e (file doc* hist* (file-name fv))))
  (values (highlight! e* fl ll) fl ll))

(define (switch-file! e i) (struct-copy editor e [active i]))
(define (toggle-sidebar! e)
  (struct-copy editor e [sidebar-open? (not (editor-sidebar-open? e))]))

;; ── 装饰：语法高亮（使用方策略）──────────────────────────

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

(define (syntax-segs doc fl ll)
  (apply append
         (for/list ([line (in-range fl (add1 ll))])
           (define text (document-line-ref doc line))
           (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
             (list line (car m) (cdr m) 'keyword)))))

(define (highlight-doc doc fl ll)
  (if fl (document-apply-patches doc (list (patch 'face fl ll (syntax-segs doc fl ll)))) doc))

(define (highlight! e fl ll)
  (define fv (current-file e))
  (put-file! e (struct-copy file fv [doc (highlight-doc (file-doc fv) fl ll)])))

;; ── 观察 ──────────────────────────────────────────────

(define (text-of e) (document->string (file-doc (current-file e))))
(define (face-of e line col) (document-get-property (file-doc (current-file e)) line col 'face))

;; ── 布局：侧边栏 + 主编辑区（使用方策略）──────────────────

;; 侧边栏：文件列表（active 加 *），做成一个只读窗口
(define sidebar-width 15)
(define (sidebar-window e height)
  (define text (string-join
                (for/list ([i (in-naturals)] [f (in-list (editor-files e))])
                  (string-append (if (= i (editor-active e)) "* " "  ") (file-name f)))
                "\n"))
  (window-open (buffer-open text) height sidebar-width))

(define (layout e)
  (define main (document-window (file-doc (current-file e)) 0))
  (define h (window-height main))
  (define mw (window-width main))
  (if (editor-sidebar-open? e)
      (screen-compose h (+ sidebar-width mw)
                      (list (list 'sidebar 0 0 (window->screen (sidebar-window e h)))
                            (list 'main sidebar-width 0 (window->screen main)))
                      'main)
      (window->screen main)))

(define (render e) (screen->text (layout e)))

;; ── 走一遍 ────────────────────────────────────────────

(module+ main
  (define e0 (make-editor (open-file "a.rkt" "hi" 4 20)
                          (open-file "b.rkt" "bye" 4 20)))
  (define-values (e1 _m1 _m2) (edit! e0 (edit-insert "define ")))
  (printf "编辑 a.rkt（含侧边栏）:\n~a\n" (render e1))
  (define e2 (switch-file! e1 1))
  (printf "切到 b.rkt:\n~a\n" (render e2))
  (define e3 (toggle-sidebar! e2))
  (printf "关掉侧边栏:\n~a\n" (render e3)))

;; ── 测试 ─────────────────────────────────────────────

(module+ test
  ;; 多文件：每个文件独立撤销
  (define e0 (make-editor (open-file "a" "abc") (open-file "b" "xyz")))
  (check-equal? (text-of e0) "abc")
  (define-values (e1 _t1 _t2) (edit! e0 (edit-insert-char #\X)))
  (check-equal? (text-of e1) "Xabc")
  (define e2 (switch-file! e1 1))
  (check-equal? (text-of e2) "xyz")
  (define-values (e3 _t3 _t4) (undo! e2))                    ; 撤销的是文件 b（空历史）→ 原样
  (check-equal? (text-of e3) "xyz")
  (define e4 (switch-file! e3 0))
  (define-values (e5 _t5 _t6) (undo! e4))                    ; 撤销文件 a → 回 "abc"
  (check-equal? (text-of e5) "abc")

  ;; 高亮：编辑出关键字，edit! 自动重标
  (define h0 (make-editor (open-file "a" "")))
  (define-values (h1 _t7 _t8) (edit! h0 (edit-insert "define ")))
  (check-equal? (face-of h1 0 1) 'keyword)

  ;; 布局：侧边栏开关
  (define l0 (make-editor (open-file "a" "hi" 1 20) (open-file "b" "yo" 1 20)))
  (check-equal? (screen-cols (layout l0)) (+ 20 sidebar-width))  ; 主 20 列 + 侧边栏 15 列
  (define l1 (toggle-sidebar! l0))
  (check-equal? (screen-cols (layout l1)) 20)            ; 关掉侧边栏 → 只剩主区

  (displayln "example.rkt: all tests passed"))
