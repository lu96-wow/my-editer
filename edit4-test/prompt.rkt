#lang racket

;;; edit4-test/prompt.rkt —— 输入行 + 资源流程（新建 / 删除 / 关文档 / 退出）

(require rackunit
         racket/list racket/file racket/path
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/tree.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/prompt.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/view/panel.rkt"
         "../edit4/boot.rkt")

(define dir (simplify-path (make-temporary-file "ed4prompt~a" 'directory)))
(display-to-file "a\n" (build-path dir "a.txt") #:exists 'truncate)
(define sub (build-path dir "sub"))
(make-directory sub)

(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))  ; 与 app 一致：插件键表在前，base 为 fallback
(define SZ (cons 80 24))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list))
(define (W st) (car st))
(define (EFF st) (cadr st))
(define (P w) (content-prompt (world-content w)))
(define (row-index ts p)
  (for/first ([r (in-list (tree-rows ts))] [i (in-naturals)]
              #:when (equal? (path-key (car r)) (path-key p))) i))
(define (path= a b) (equal? (path-key a) (path-key b)))

;;; ---------- 世界：树面板已写回，可定位光标 ----------

(define (tree-world)
  (define w (boot #:root dir #:name "*scratch*"))
  (define c (world-content w))
  (define ed (content-ed c))
  (commit-panels! ed (project-panels base-panels w))
  (define tv (content-panel-vid c "*tree*"))
  (define tw (for/first ([id (in-list (ids (world-layout w)))] #:when (eqv? (content-vid-of c id) tv)) id))
  (define ew (for/first ([id (in-list (ids (world-layout w)))] #:when (eqv? (content-vid-of c id) (content-vid-of c 0))) id))
  (values w c ed tv tw ew))

;;; ---------- 新建文件：C-n 前缀 → f → 输入名 → Enter ----------

(define-values (w0 c0 ed0 tvid tw0 ewid0) (tree-world))
(set-point! ed0 tvid 0 0)                       ; 光标在根目录行
(define s1 (run (world-set-focus w0 tw0) (key-event 'n '(ctrl))))
(check-equal? (world-prefix (W s1)) 'new)       ; 进入 new 前缀
(define s2 (run (W s1) (text-event "f")))       ; 触发 tree-new-file → 打开输入行
(check-not-false (P (W s2)))
(check-equal? (prompt-kind (P (W s2))) 'new-file)
(check-equal? (world-focus (W s2)) (prompt-wid (P (W s2))))   ; 焦点在输入行
(define s3 (run (W s2) (text-event "new.txt")))
(define s4 (run (W s3) (key-event 'enter '())))
(check-false (P (W s4)))                        ; 提交后输入行关闭
(check-true (for/or ([e (in-list (EFF s4))] #:when (make-file? e))
              (path= (make-file-path e) (build-path dir "new.txt"))))
(check-true (for/or ([e (in-list (EFF s4))]) (reload-tree? e)))

;;; ---------- 新建目录：C-n C-n（new2）→ f → 输入名 → Enter ----------

(define-values (w1 c1 ed1 tvid1 tw1 _a) (tree-world))
(set-point! ed1 tvid1 0 0)
(define n1 (run (world-set-focus w1 tw1) (key-event 'n '(ctrl))))   ; prefix new
(define n1b (run (W n1) (key-event 'n '(ctrl))))                     ; → prefix new2
(define n2 (run (W n1b) (text-event "f")))                          ; tree-new-dir
(check-equal? (prompt-kind (P (W n2))) 'new-dir)
(define n3 (run (W n2) (text-event "sub2")))
(define n4 (run (W n3) (key-event 'enter '())))
(check-true (for/or ([e (in-list (EFF n4))] #:when (make-dir? e))
              (path= (make-dir-path e) (build-path dir "sub2"))))

;;; ---------- 删除：树焦点 + C-d → 确认 ----------

(define-values (w2 c2 ed2 tvid2 tw2 _b) (tree-world))
(set-point! ed2 tvid2 (row-index (content-tree c2) (build-path dir "a.txt")) 0)
(define d1 (run (world-set-focus w2 tw2) (key-event 'd '(ctrl))))
(check-equal? (prompt-kind (P (W d1))) 'delete)
(define d2 (run (W d1) (text-event "y")))
(define d3 (run (W d2) (key-event 'enter '())))
(check-true (for/or ([e (in-list (EFF d3))] #:when (delete-path? e))
              (path= (delete-path-path e) (build-path dir "a.txt"))))

;;; ---------- 关文档：脏 → 询问 → n → 关闭 ----------

(define-values (w3 c3 ed3 _tvid3 _tw3 ewid3) (tree-world))
(define dirty1 (run (world-set-focus w3 ewid3) (text-event "dirty")))
(define cd3 (world-content (W dirty1)))
(check-true (doc-dirty? cd3 (content-did-of cd3 (content-vid-of cd3 ewid3))))
(define ndocs (length (document-id-list (content-ed cd3))))
(define cl1 (call-with-values (lambda () (request-close-doc (W dirty1))) list))
(check-equal? (prompt-kind (P (W cl1))) 'close-doc)
(define cl2 (run (W cl1) (text-event "n")))
(define cl3 (run (W cl2) (key-event 'enter '())))
(check-equal? (length (document-id-list (content-ed (world-content (W cl3))))) (sub1 ndocs))

;;; ---------- 退出：脏 → 询问 → nall → quit-effect ----------

(define-values (w4 c4 ed4 _tvid4 _tw4 ewid4) (tree-world))
(define dirty2 (run (world-set-focus w4 ewid4) (text-event "x")))
(define q1 (run (W dirty2) (key-event 'q '(ctrl))))
(check-equal? (prompt-kind (P (W q1))) 'quit)
(define q2 (run (W q1) (text-event "nall")))
(define q3 (run (W q2) (key-event 'enter '())))
(check-true (for/or ([e (in-list (EFF q3))]) (quit-effect? e)))

;;; ---------- 退出：无脏 → 直接 quit ----------

(define-values (w5 c5 ed5 _tvid5 _tw5 _ewid5) (tree-world))
(define q4 (run w5 (key-event 'q '(ctrl))))
(check-true (for/or ([e (in-list (EFF q4))]) (quit-effect? e)))

(displayln "edit4/prompt.rkt: all tests passed")
