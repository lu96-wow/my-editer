#lang racket

;;; core/compose/example.rkt —— 使用方示范：多 buffer + 侧边栏 + 局部高亮
;;;
;;; editor 现在是多 buffer 平台：每个打开的「文件」是一个 buffer-entry（id + name + buffer + 账本），
;;; 焦点决定当前编辑哪个 buffer。本文件只加「使用方自己的状态」：侧边栏开关、布局。
;;;
;;; 命令形状：
;;;   (define-values (ed report) (editor-edit ed (edit-insert-char #\a)))
;;;   report 是 (or/c #f change-report)；要重绘就 (change-report-first-line report)。

(require "../editor.rkt" racket/list rackunit)

;;; ---------- 使用方自己的状态 ----------

(struct file-spec (name text height width) #:transparent)
(struct app (editor sidebar-open?) #:transparent)

(define (open-file name [text ""] [height 24] [width 60])
  (file-spec name text height width))

(define (make-app . specs)
  (define fs (if (null? specs) (list (open-file "*scratch*")) specs))
  (define f0 (car fs))
  (define ed0 (editor-open (file-spec-text f0) (file-spec-height f0) (file-spec-width f0)
                           #:name (file-spec-name f0)))
  (define ed (for/fold ([e ed0]) ([f (in-list (cdr fs))])
               (define-values (e* _bid)
                 (editor-open-buffer e (file-spec-name f) (file-spec-text f)
                                     (file-spec-height f) (file-spec-width f)))
               e*))
  (app (editor-focus-buffer ed 0) #t))

(define (current-buffer-id e) (editor-focused-buffer-id (app-editor e)))
(define (toggle-sidebar! e)
  (struct-copy app e [sidebar-open? (not (app-sidebar-open? e))]))

;;; ---------- 命令：把 editor-* 接进自己的状态 ----------

(define (run-command e cmd)
  (define-values (ed* report) (cmd (app-editor e)))
  (values (highlight! (struct-copy app e [editor ed*]) report) report))

(define (edit! e op) (run-command e (lambda (ed) (editor-edit ed op))))
(define (undo! e) (run-command e editor-undo))
(define (redo! e) (run-command e editor-redo))

;; 切换当前 buffer（焦点）——多 buffer 的「切文件」
(define (switch-file! e bid)
  (struct-copy app e [editor (editor-focus-buffer (app-editor e) bid)]))

;;; ---------- 装饰：语法高亮（使用方策略，按焦点 buffer 局部重标）----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

(define (syntax-segs ed bid fl ll)
  (append*
   (for/list ([line (in-range fl (add1 ll))])
     (define text (editor-buffer-line-ref ed bid line))
     (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
       (list line (car m) (cdr m) 'keyword)))))

(define (highlight! e report)
  (cond
    [(not report) e]
    [else
     (define ed (app-editor e))
     (define bid (current-buffer-id e))
     (define fl (change-report-first-line report))
     (define ll (change-report-last-line report))
     (struct-copy app e
       [editor (editor-apply-patches ed bid (list (patch 'face fl ll (syntax-segs ed bid fl ll))))])]))

;;; ---------- 观察 ----------

(define (text-of e) (editor-buffer->string (app-editor e) (current-buffer-id e)))
(define (face-of e line col)
  (editor-get-property (app-editor e) (current-buffer-id e) (point line col) 'face))

;;; ---------- 布局：侧边栏 + 主编辑区 ----------

(define sidebar-width 15)

(define (sidebar-window e height)
  (define ed (app-editor e))
  (define cur (current-buffer-id e))
  (window-open
   (buffer-open
    (string-join (for/list ([b (in-list (editor-buffers ed))])
                   (string-append (if (= (buffer-entry-id b) cur) "* " "  ")
                                  (buffer-entry-name b)))
                 "\n"))
   height sidebar-width))

(define (layout e)
  (define ed (app-editor e))
  (define h (editor-height ed))
  (define mw (editor-width ed))
  (if (app-sidebar-open? e)
      (editor-screen-compose h (+ sidebar-width mw)
                             (list (list 'sidebar 0 0 (window->screen (sidebar-window e h)))
                                   (list 'main sidebar-width 0 (editor->screen ed)))
                             'main)
      (editor->screen ed)))

(define (render e) (editor-screen->text (layout e)))

;;; ---------- 走一遍 ----------

(module+ main
  (define e0 (make-app (open-file "a.rkt" "hi" 4 20)
                       (open-file "b.rkt" "bye" 4 20)))
  (define-values (e1 _u1) (edit! e0 (edit-insert "define ")))
  (printf "编辑 a.rkt（含侧边栏）:\n~a\n" (render e1))
  (printf "把焦点切到 buffer id=1:\n~a\n" (render (switch-file! e1 1)))
  (printf "关掉侧边栏:\n~a\n" (render (toggle-sidebar! (switch-file! e1 1)))))

;;; ---------- 测试 ----------

(module+ test
  ;; 多 buffer：撤销按 buffer 独立
  (define e0 (make-app (open-file "a" "abc") (open-file "b" "xyz")))
  (define-values (e1 _u2) (edit! e0 (edit-insert-char #\X)))
  (check-equal? (text-of e1) "Xabc")
  (define e2 (switch-file! e1 1))
  (define-values (e3 _u3) (undo! e2))                 ; b 无历史 → 原样
  (check-equal? (text-of e3) "xyz")
  (define-values (e4 _u4) (undo! (switch-file! e3 0)))
  (check-equal? (text-of e4) "abc")

  ;; 高亮：edit! 自动按焦点 buffer 局部重标
  (define h1 (let-values ([(e _u5) (edit! (make-app (open-file "a" "")) (edit-insert "define "))]) e))
  (check-equal? (face-of h1 0 1) 'keyword)

  ;; 布局：侧边栏开关
  (define l0 (make-app (open-file "a" "hi" 1 20) (open-file "b" "yo" 1 20)))
  (check-equal? (screen-cols (layout l0)) (+ 20 sidebar-width))
  (check-equal? (screen-cols (layout (toggle-sidebar! l0))) 20)

  (displayln "example.rkt: all tests passed"))
