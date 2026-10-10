#lang racket

;;; plugins/test/docs-local-test.rkt —— 文档窗口两步走 + 来源反查（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/docs-local-test.rkt
;;;
;;; 标准库文档（worker + xref，缓存）先显示；本地定义（主线程扫缓冲区）后一步追加。
;;; 覆盖：本地定义；标准库 + 本地同名；prefix-in 候选名 → 原名去本地文件查。

(require rackunit
         racket/file
         racket/string
         "../../core/app/app.rkt"
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/focus.rkt"
         "../../core/session/edit.rkt"
         "../../core/session/render.rkt"
         "../../core/focus.rkt"
         "../../core/command/command.rkt"
         "../../core/path.rkt"
         "../catalog.rkt"
         "../ui/document.rkt")

(define (render s)
  (call-with-values (lambda () (session-render s #f)) (lambda (s* . _) s*)))

;; 文档窗正文（常驻 *docs* 文档；空 = 尚未显示内容 → #f）。
(define (docs-str s)
  (for/first ([did (in-list (session-document-ids s))]
              #:when (equal? (session-document-name s did) "*docs*"))
    (define t (session-document-string s did))
    (and (positive? (string-length t)) t)))

;; 依次打开 open-paths（最后一个为焦点），光标放 (line,col)，M-d，等文档窗。
(define (docs-after open-paths line col)
  (define s0 (for/fold ([s (app-session 80 24 #:plugins enabled-plugins)]) ([p (in-list open-paths)])
               (render (session-open-file s (normalize p)))))
  ;; 明确焦点到**最后打开**的文件（session-edit-vid 不一定随打开更新）
  (define tdid (session-file-did s0 (normalize (last open-paths))))
  (define evid (car (session-document-view-list s0 tdid)))
  (define s1 (session-set-focus s0 (focus-set (session-focus s0) evid)))
  (define s2 (step (session-ed-set-point! s1 evid line col) (cmd-docs-show)))
  (for/fold ([s (render s2)]) ([i (in-range 300)])
    (define s* (render s))
    (if (docs-str s*) s* (begin (sleep 0.05) s*))))

;;; ---------- 1. 本地定义：标准库查不到，第二步本地段出来 ----------

(define p (make-temporary-file "dloc-~a.rkt"))
(display-to-file "#lang racket/base\n(define (my-local-fn x)\n  (+ x 1))\n" p #:exists 'replace)
(define t1 (docs-str (docs-after (list p) 1 10)))
(check-not-false t1)
(check-not-false (regexp-match? #rx"本地定义" t1))
(check-not-false (regexp-match? #rx"my-local-fn" t1))
(delete-file p)

;;; ---------- 2. 标准库 + 本地同名：本地段置顶，标准库也在 ----------

(define p2 (make-temporary-file "dloc2-~a.rkt"))
(display-to-file "#lang racket/base\n(require racket/list)\n(define (first x) x)\n" p2 #:exists 'replace)
(define t2 (docs-str (docs-after (list p2) 2 10)))
(check-not-false t2)
(check-not-false (regexp-match? #rx"本地定义" t2))
(check-not-false (string-contains? t2 "(define (first"))
(delete-file p2)

;;; ---------- 3. prefix-in：候选名 l:foo → 原名 foo 去打开的本地文件查 ----------

(define dir (build-path (find-system-path 'temp-dir) (format "dlp-~a" (random))))
(make-directory dir)
(define lib (build-path dir "lib.rkt"))
(define main (build-path dir "main.rkt"))
(display-to-file "#lang racket/base\n(provide foo)\n(define (foo x) x)\n" lib #:exists 'replace)
(display-to-file "#lang racket/base\n(require (prefix-in l: \"lib.rkt\"))\n(define y l:foo)\n" main #:exists 'replace)
(define t3 (docs-str (docs-after (list lib main) 2 10)))   ; 光标在 l:foo 上
(check-not-false t3)
(check-not-false (regexp-match? #rx"本地定义" t3))
(check-not-false (string-contains? t3 "(define (foo x) x)"))
(delete-file lib)
(delete-file main)
(delete-directory dir)
