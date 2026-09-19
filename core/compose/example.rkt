#lang racket

;;; core/compose/example.rkt —— 使用方示范：自己拼一个多文件编辑器
;;;
;;; 组合层只给 editor（document+账本+活动视图）与 editor-edit/undo/redo。
;;; 多文件状态、侧边栏布局、语法高亮全是使用方自己拼的。
;;;
;;; 看看现在接一个命令有多直白（不用记参数/返回值顺序）：
;;;   (define-values (s report) (editor-edit s (edit-insert-char #\a)))
;;;   ;; report 是 (or/c #f change-report)；要重绘就 (change-report-first-line report)…

(require "../editor.rkt" racket/list rackunit)

;;; ---------- 使用方自己的状态 ----------

(struct file (editor name) #:transparent)     ; 每个文件一个 editor（含自己的账本）
(struct app (files active sidebar-open?) #:transparent)

(define (open-file name [text ""] [height 24] [width 60])
  (file (editor-open text height width) name))

(define (make-app . files)
  (app (if (null? files) (list (open-file "*scratch*")) files) 0 #t))

(define (current-file e) (list-ref (app-files e) (app-active e)))
(define (put-file e f)
  (struct-copy app e [files (list-set (app-files e) (app-active e) f)]))

;;; ---------- 命令：把 editor-* 接进自己的状态 ----------

(define (run-command e cmd)
  (define fv (current-file e))
  (define-values (s* report) (cmd (file-editor fv)))
  (define e* (put-file e (file s* (file-name fv))))
  (values (highlight! e* report) report))

(define (edit! e op) (run-command e (lambda (s) (editor-edit s op))))
(define (undo! e) (run-command e editor-undo))
(define (redo! e) (run-command e editor-redo))

(define (switch-file! e i) (struct-copy app e [active i]))
(define (toggle-sidebar! e) (struct-copy app e [sidebar-open? (not (app-sidebar-open? e))]))

;;; ---------- 装饰：语法高亮（使用方策略）----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

(define (syntax-segs ed fl ll)
  (append*
   (for/list ([line (in-range fl (add1 ll))])
     (define text (editor-line-ref ed line))
     (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
       (list line (car m) (cdr m) 'keyword)))))

;; 只重标高亮**变更行**（report 给的区间）；report #f 表示无事发生。
(define (highlight! e report)
  (cond
    [(not report) e]
    [else
     (define fv (current-file e))
     (define ed (file-editor fv))
     (define fl (change-report-first-line report))
     (define ll (change-report-last-line report))
     (put-file e (file (editor-apply-patches ed (list (patch 'face fl ll (syntax-segs ed fl ll))))
                       (file-name fv)))]))

;;; ---------- 观察 ----------

(define (text-of e) (editor->string (file-editor (current-file e))))
(define (face-of e line col)
  (editor-get-property (file-editor (current-file e)) line col 'face))

;;; ---------- 布局：侧边栏 + 主编辑区 ----------

(define sidebar-width 15)

(define (sidebar-window e height)
  (window-open
   (buffer-open
    (string-join (for/list ([i (in-naturals)] [f (in-list (app-files e))])
                   (string-append (if (= i (app-active e)) "* " "  ") (file-name f)))
                 "\n"))
   height sidebar-width))

(define (layout e)
  (define ed (file-editor (current-file e)))
  (define main (editor-window ed))
  (define h (window-height main))
  (define mw (window-width main))
  (if (app-sidebar-open? e)
      (editor-screen-compose h (+ sidebar-width mw)
                      (list (list 'sidebar 0 0 (window->screen (sidebar-window e h)))
                            (list 'main sidebar-width 0 (editor->screen ed)))
                      'main)
      (editor->screen ed)))

(define (render e) (screen->text (layout e)))

;;; ---------- 走一遍 ----------

(module+ main
  (define e0 (make-app (open-file "a.rkt" "hi" 4 20)
                          (open-file "b.rkt" "bye" 4 20)))
  (define-values (e1 _u1) (edit! e0 (edit-insert "define ")))
  (printf "编辑 a.rkt（含侧边栏）:\n~a\n" (render e1))
  (printf "切到 b.rkt:\n~a\n" (render (switch-file! e1 1)))
  (printf "关掉侧边栏:\n~a\n" (render (toggle-sidebar! (switch-file! e1 1)))))

;;; ---------- 测试 ----------

(module+ test
  ;; 多文件：撤销按文件独立
  (define e0 (make-app (open-file "a" "abc") (open-file "b" "xyz")))
  (define-values (e1 _u2) (edit! e0 (edit-insert-char #\X)))
  (check-equal? (text-of e1) "Xabc")
  (define e2 (switch-file! e1 1))
  (define-values (e3 _u3) (undo! e2))                 ; b 无历史 → 原样
  (check-equal? (text-of e3) "xyz")
  (define-values (e4 _u4) (undo! (switch-file! e3 0)))
  (check-equal? (text-of e4) "abc")

  ;; 高亮：edit! 自动重标
  (define h1 (let-values ([(e _) (edit! (make-app (open-file "a" "")) (edit-insert "define "))]) e))
  (check-equal? (face-of h1 0 1) 'keyword)

  ;; 布局：侧边栏开关
  (define l0 (make-app (open-file "a" "hi" 1 20) (open-file "b" "yo" 1 20)))
  (check-equal? (screen-cols (layout l0)) (+ 20 sidebar-width))
  (check-equal? (screen-cols (layout (toggle-sidebar! l0))) 20)

  (displayln "example.rkt: all tests passed"))
