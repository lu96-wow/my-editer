#lang racket

;;; edit/plugins/test/auto-pair-test.rkt —— 括号自动配对（headless）
;;;
;;;   raco test edit/plugins/test/auto-pair-test.rkt
;;;
;;; 覆盖：左括号成对插入 + 光标停中间；右括号跳过已存在的；
;;;       有选区时不配对（保持“替换选区”原语义）；dock 面（输入行）不配对。

(require rackunit
         racket/file
         "../../core/app/app.rkt"
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/focus.rkt"
         "../../core/session/panel.rkt"
         "../../core/session/render.rkt"
         "../../core/command/input.rkt"
         "../../core/command/engine.rkt"
         "../../core/command/key.rkt"
         "../../core/command/binding.rkt"
         "../../core/path.rkt"
         "../catalog.rkt"
         "../ui/document.rkt"
         "../ui/ids.rkt")

(define (render s)
  (call-with-values (lambda () (session-render s #f)) (lambda (s* . _) s*)))

;; 产生一个「文本插入」输入并派发。
(define (type s text) (engine-dispatch s (input text-binding text #f #f #f #f)))

(define (cursor s vid)
  (list (session-view-point-line s vid) (session-view-point-column s vid)))

;;; ---------- 准备：打开一个空 Racket 文件并聚焦编辑视图 ----------

(define p (make-temporary-file "pair-~a.rkt"))
(display-to-file "" p #:exists 'replace)
(define s0 (render (session-open-file (app-session 80 24 #:plugins enabled-plugins) (normalize p))))
(define evid (session-edit-vid s0))
(check-not-false evid)

;;; ---------- 1. 左括号成对插入，光标停中间 ----------

(define s1 (type s0 "{"))
(check-equal? (session-view-string s1 evid) "{}")
(check-equal? (cursor s1 evid) '(0 1))

;;; ---------- 2. 右括号跳过已存在的（不重复插入） ----------

(define s2 (type s1 "}"))
(check-equal? (session-view-string s2 evid) "{}")
(check-equal? (cursor s2 evid) '(0 2))

;;; ---------- 3. [] 同样配对（在文件末尾继续） ----------

(define s3 (type s2 "["))
(check-equal? (session-view-string s3 evid) "{}[]")
(check-equal? (cursor s3 evid) '(0 3))
(define s4 (type s3 "]"))
(check-equal? (session-view-string s4 evid) "{}[]")
(check-equal? (cursor s4 evid) '(0 4))

;;; ---------- 4. () 也配对 ----------

(define s5 (type s4 "("))
(check-equal? (session-view-string s5 evid) "{}[]()")
(check-equal? (cursor s5 evid) '(0 5))

;;; ---------- 5. 有选区时不配对：保持替换选区 ----------

(define s6 (engine-dispatch (engine-dispatch s5 (input (key 'a 'ctrl) #f #f #f #f #f)) ; cmd-select-all
                     (input text-binding "{" #f #f #f #f)))
(check-equal? (session-view-string s6 evid) "{")   ; 选区被整体替换，而不是包一层 {…}

;;; ---------- 6. 输入行（dock 面）不配对 ----------

(define s7 (engine-dispatch s6 (input (key 'f 'ctrl) #f #f #f #f #f)))   ; cmd-open-file → 打开输入行
(define ivid (session-panel-vid s7 panel-input))
(check-not-false ivid)
(define s8 (engine-dispatch s7 (input text-binding "{" #f #f #f #f)))
(check-equal? (session-view-string s8 ivid) "find file: {")      ; 只插入一个 {

(delete-file p)
