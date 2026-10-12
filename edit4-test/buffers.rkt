#lang racket

;;; edit4-test/buffers.rkt —— 文档管理面板 + 面板槽（region）+ 命令序列显示

(require rackunit
         racket/list racket/file racket/path
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/buffers.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/view/buffers.rkt"
         "../edit4/view/status.rkt"
         "../edit4/view/panel.rkt"
         "../edit4/boot.rkt")

(define dir (simplify-path (make-temporary-file "ed4buf~a" 'directory)))

(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))
(define SZ (cons 80 24))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list))
(define (W st) (car st))
(define (window-of w vid)
  (for/first ([id (in-list (ids (world-layout w)))]
              #:when (eqv? (content-vid-of (world-content w) id) vid))
    id))
(define (row-index rows pred)
  (for/first ([r (in-list rows)] [i (in-naturals)] #:when (pred r)) i))
(define (status-content-text w vid)
  (car (call-with-values (lambda () (status-content w vid)) list)))
(define (sidebar-active w)
  (region-active (hash-ref (content-regions (world-content w)) 'sidebar)))

;;; ---------- 准备：编辑器文档 + 第二个文档 ----------

(define w0 (boot #:root dir))
(define c0 (world-content w0))
(define-values (c1 did2 vid2) (content-add-doc! c0 "second" 40 10 "second" #f))
(define w1 (world-set-content w0 c1))
(define ed1 (content-ed c1))
(commit-panels! ed1 (project-panels base-panels w1))
(define bvid (content-panel-vid c1 "*buffers*"))
(define tvid (content-panel-vid c1 "*tree*"))
(define svid (content-panel-vid c1 "*status*"))
(define swid (window-of w1 tvid))          ; 侧栏窗（初始显示 tree）
(define ewid (window-of w1 (content-vid-of c1 0)))
(define i2 (row-index (buffer-rows w1)
                      (lambda (r) (and (eq? (list-ref r 4) 'doc) (equal? (caddr r) "second")))))

;;; ---------- 行模型 / 投影 ----------

(define rows (buffer-rows w1))
(check-true (for/or ([r (in-list rows)] #:when (equal? (caddr r) "second")) #t))
(check-true (for/or ([r (in-list rows)] #:when (equal? (caddr r) "*scratch*")) #t))
(check-false (for/or ([r (in-list rows)]
                      #:when (member (caddr r) '("*tree*" "*buffers*" "*status*")))
               #t))
(check-true (regexp-match? #rx"second" (car (call-with-values (lambda () (buffers-content w1 bvid)) list))))

;;; ---------- 面板槽：M-b 让侧栏显示 buffers 并聚焦 ----------

(define s1 (run w1 (key-event 'b '(alt))))
(check-equal? (sidebar-active (W s1)) "*buffers*")
(check-equal? (content-vid-of (world-content (W s1)) swid) bvid)
(check-equal? (world-focus (W s1)) swid)

;;; ---------- 折叠：空格折叠第二个文档（焦点在 buffers 面板） ----------

(set-point! (content-ed (world-content (W s1))) bvid i2 0)
(define f1 (run (W s1) (text-event " ")))
(check-true (hash-has-key? (content-fold (world-content (W f1))) did2))
;; 折叠后第二个文档的视图行消失
(check-false (for/or ([r (in-list (buffer-rows (W f1)))]
                      #:when (and (eq? (list-ref r 4) 'view) (eqv? (car r) did2)))
               #t))

;;; ---------- buffers-enter：显示选中的文档到编辑器窗 ----------

(set-point! (content-ed (world-content (W s1))) bvid i2 0)
(define e1 (run (W s1) (key-event 'enter '())))
(check-equal? (content-vid-of (world-content (W e1)) ewid) vid2)

;;; ---------- M-e：聚焦编辑器 ----------
(define me (run (W s1) (key-event 'e '(alt))))
(check-equal? (world-focus (W me)) ewid)

;;; ---------- Tab（region 作用域）：切换侧栏成员 ----------

(define tab1 (run (world-set-focus w1 swid) (key-event 'tab '())))
(check-equal? (sidebar-active (W tab1)) "*buffers*")
(define tab2 (run (W tab1) (key-event 'tab '())))
(check-equal? (sidebar-active (W tab2)) "*tree*")

;;; ---------- 命令序列显示：切回 tree，C-n ----------

(define g1 (run w1 (key-event 't '(alt))))          ; 侧栏切回 tree 并聚焦
(check-equal? (sidebar-active (W g1)) "*tree*")
(check-equal? (content-vid-of (world-content (W g1)) swid) tvid)
(define g2 (run (W g1) (key-event 'n '(ctrl))))
(check-equal? (world-prefix (W g2)) 'new)
(check-equal? (world-keys (W g2)) (list "C-n"))
(check-true (regexp-match? #rx"C-n" (status-content-text (W g2) svid)))
(define g3 (run (W g2) (text-event "f")))            ; 完成 → 清空
(check-equal? (world-keys (W g3)) '())

;;; ---------- new-view / 关视图（buffers 面板） ----------

(define u0 (run w1 (key-event 'b '(alt))))
(commit-panels! (content-ed (world-content (W u0))) (project-panels base-panels (W u0)))
(set-point! (content-ed (world-content (W u0))) bvid i2 0)
(define n1 (run (W u0) (text-event "n")))            ; new-view on did2
(check-equal? (length (document-view-list (content-ed (world-content (W n1))) did2)) 2)
;; 关掉 did2 的一个视图
(commit-panels! (content-ed (world-content (W n1))) (project-panels base-panels (W n1)))
(define vi (row-index (buffer-rows (W n1))
                      (lambda (r) (and (eq? (list-ref r 4) 'view) (eqv? (car r) did2)))))
(check-not-false vi)
(set-point! (content-ed (world-content (W n1))) bvid vi 0)
(define n2 (run (W n1) (key-event 'd '(ctrl))))      ; buffers-close-view
(check-equal? (length (document-view-list (content-ed (world-content (W n2))) did2)) 1)

(displayln "edit4/buffers.rkt: all tests passed")
