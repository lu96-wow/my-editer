#lang racket

;;; edit-rebuild/core/test/engine-test.rkt —— 新引擎：基本输入 + 命令路由
;;;
;;;   raco test edit-rebuild/core/test/engine-test.rkt

(require rackunit
         racket/file
         "../app/app.rkt"
         "../command/input.rkt"
         "../command/engine.rkt"
         "../command/key.rkt"
         "../command/keys.rkt"
         "../session/session.rkt"
         "../session/adapter.rkt"
         "../session/focus.rkt"
         "../session/render.rkt"
         "../session/panel.rkt"
         "../session/bottom.rkt"
         "../focus.rkt"
         "../keymap.rkt"
         "../path.rkt"
         "../../plugins/catalog.rkt"
         "../../plugins/ui/document.rkt"
         "../../plugins/ui/ids.rkt")

(define (render s)
  (call-with-values (lambda () (session-render s #f)) (lambda (s* . _) s*)))
(define (in* b [text #f]) (input b text #f #f #f #f))

;;; ---------- 基本输入（文本 / 导航 / 前缀） ----------

(define (blank-with-doc)
  (define s (session-blank 80 24 (list base-keys)))
  (define-values (s1 did vid) (session-add-document s "abc" 40 10 #:name "*t*"))
  (values (session-set-focus s1 (focus-set (session-focus s1) vid)) vid))

(let-values ([(s vid) (blank-with-doc)])
  (check-equal? (session-view-string (engine-dispatch s (in* text-binding "X")) vid) "Xabc"))

(let-values ([(s vid) (blank-with-doc)])
  (define s1 (engine-dispatch s (in* (key 'left))))
  (check-equal? (session-view-string (engine-dispatch s1 (in* text-binding "Y")) vid) "Yabc"))

(let-values ([(s vid) (blank-with-doc)])
  (define s1 (engine-dispatch s (in* (key 'p 'ctrl))))
  (check-true (prefix? (session-prefix s1)))
  (check-false (session-prefix (engine-dispatch s1 (in* (key 'escape))))))

;;; ---------- command 路由：焦点在日志面板时 Escape → cmd-log-close ----------

(define p (make-temporary-file "eng-~a.rkt"))
(display-to-file "hello world\n" p #:exists 'replace)
(define s0 (render (session-open-file (app-session 80 24 #:plugins enabled-plugins) (normalize p))))

(let* ([s (session-bottom-pop s0 panel-log)])
  (check-true (session-visible? s (session-panel-vid s panel-log)))
  (define s* (engine-dispatch s (in* (key 'escape))))
  (check-false (session-visible? s* (session-panel-vid s* panel-log)))
  (check-true (session-visible? s* (session-panel-vid s* panel-status))))

(delete-file p)
