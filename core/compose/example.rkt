#lang racket

;;; core/compose/example.rkt —— 使用方示范：自己拼一个多文件编辑器
;;;
;;; 组合层只给 session（document+账本+活动视图）与 compose-edit/undo/redo。
;;; 多文件状态、侧边栏布局、语法高亮全是使用方自己拼的。
;;;
;;; 看看现在接一个命令有多直白（不用记参数/返回值顺序）：
;;;   (define-values (s report) (compose-edit s (edit-insert-char #\a)))
;;;   ;; report 是 (or/c #f change-report)；要重绘就 (change-report-first-line report)…

(require "../api.rkt" "editor.rkt" racket/list rackunit)

;;; ---------- 使用方自己的状态 ----------

(struct file (session name) #:transparent)     ; 每个文件一个 session（含自己的账本）
(struct editor (files active sidebar-open?) #:transparent)

(define (open-file name [text ""] [height 24] [width 60])
  (file (session-open text height width) name))

(define (make-editor . files)
  (editor (if (null? files) (list (open-file "*scratch*")) files) 0 #t))

(define (current-file e) (list-ref (editor-files e) (editor-active e)))
(define (put-file e f)
  (struct-copy editor e [files (list-set (editor-files e) (editor-active e) f)]))

;;; ---------- 命令：把 compose-* 接进自己的状态 ----------

(define (run-command e cmd)
  (define fv (current-file e))
  (define-values (s* report) (cmd (file-session fv)))
  (define e* (put-file e (file s* (file-name fv))))
  (values (highlight! e* report) report))

(define (edit! e op) (run-command e (lambda (s) (compose-edit s op))))
(define (undo! e) (run-command e compose-undo))
(define (redo! e) (run-command e compose-redo))

(define (switch-file! e i) (struct-copy editor e [active i]))
(define (toggle-sidebar! e) (struct-copy editor e [sidebar-open? (not (editor-sidebar-open? e))]))

;;; ---------- 装饰：语法高亮（使用方策略）----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

(define (syntax-segs doc fl ll)
  (append*
   (for/list ([line (in-range fl (add1 ll))])
     (define text (document-line-ref doc line))
     (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
       (list line (car m) (cdr m) 'keyword)))))

;; 只重标高亮**变更行**（report 给的区间）；report #f 表示无事发生。
(define (highlight! e report)
  (cond
    [(not report) e]
    [else
     (define fv (current-file e))
     (define s (file-session fv))
     (define doc (session-document s))
     (define fl (change-report-first-line report))
     (define ll (change-report-last-line report))
     (define doc* (document-apply-patches doc (list (patch 'face fl ll (syntax-segs doc fl ll)))))
     (put-file e (file (struct-copy session s [document doc*]) (file-name fv)))]))

;;; ---------- 观察 ----------

(define (text-of e) (document->string (session-document (file-session (current-file e)))))
(define (face-of e line col)
  (document-get-property (session-document (file-session (current-file e))) line col 'face))

;;; ---------- 布局：侧边栏 + 主编辑区 ----------

(define sidebar-width 15)

(define (sidebar-window e height)
  (window-open
   (buffer-open
    (string-join (for/list ([i (in-naturals)] [f (in-list (editor-files e))])
                   (string-append (if (= i (editor-active e)) "* " "  ") (file-name f)))
                 "\n"))
   height sidebar-width))

(define (layout e)
  (define main (session-window (file-session (current-file e))))
  (define h (window-height main))
  (define mw (window-width main))
  (if (editor-sidebar-open? e)
      (screen-compose h (+ sidebar-width mw)
                      (list (list 'sidebar 0 0 (window->screen (sidebar-window e h)))
                            (list 'main sidebar-width 0 (window->screen main)))
                      'main)
      (window->screen main)))

(define (render e) (screen->text (layout e)))

;;; ---------- 走一遍 ----------

(module+ main
  (define e0 (make-editor (open-file "a.rkt" "hi" 4 20)
                          (open-file "b.rkt" "bye" 4 20)))
  (define-values (e1 _u1) (edit! e0 (edit-insert "define ")))
  (printf "编辑 a.rkt（含侧边栏）:\n~a\n" (render e1))
  (printf "切到 b.rkt:\n~a\n" (render (switch-file! e1 1)))
  (printf "关掉侧边栏:\n~a\n" (render (toggle-sidebar! (switch-file! e1 1)))))

;;; ---------- 测试 ----------

(module+ test
  ;; 多文件：撤销按文件独立
  (define e0 (make-editor (open-file "a" "abc") (open-file "b" "xyz")))
  (define-values (e1 _u2) (edit! e0 (edit-insert-char #\X)))
  (check-equal? (text-of e1) "Xabc")
  (define e2 (switch-file! e1 1))
  (define-values (e3 _u3) (undo! e2))                 ; b 无历史 → 原样
  (check-equal? (text-of e3) "xyz")
  (define-values (e4 _u4) (undo! (switch-file! e3 0)))
  (check-equal? (text-of e4) "abc")

  ;; 高亮：edit! 自动重标
  (define h1 (let-values ([(e _) (edit! (make-editor (open-file "a" "")) (edit-insert "define "))]) e))
  (check-equal? (face-of h1 0 1) 'keyword)

  ;; 布局：侧边栏开关
  (define l0 (make-editor (open-file "a" "hi" 1 20) (open-file "b" "yo" 1 20)))
  (check-equal? (screen-cols (layout l0)) (+ 20 sidebar-width))
  (check-equal? (screen-cols (layout (toggle-sidebar! l0))) 20)

  (displayln "example.rkt: all tests passed"))
