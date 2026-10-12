#lang racket

;;; edit4-test/plugins.rkt —— 插件通道：装配 fold + 自动配对 + 括号装饰
;;;
;;; 验证 plugin 契约足以承载「无状态插件」：命令 / 键表覆盖 / decor 追加，
;;; 以及 auto-pair（编辑行为）与 bracket-decor（显示）两个真实插件。

(require rackunit racket/list racket/path
         "../edit4/app.rkt"
         "../edit4/env.rkt"
         "../edit4/core/world.rkt" "../edit4/core/event.rkt"
         "../edit4/core/command.rkt" "../edit4/core/dispatch.rkt"
         "../edit4/content/model.rkt" "../edit4/content/adapter.rkt"
         "../edit4/view/decor.rkt"
         "../edit4/view/face.rkt"
         "../edit4/decor/bracket.rkt"
         "../edit4/layout.rkt")

(define env (app-environment))

;; 单窗 + 一个 Racket 文档。
(define (world-with text)
  (define c0 (content-blank))
  (define-values (c1 _did v) (content-add-doc! c0 text 40 3 "t" (string->path "t.rkt")))
  (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 v)))

(define (send w ev)
  (define-values (w* _effs)
    (dispatch (environment-commands env) (environment-scopes env)
              (environment-keymap env) (ctx ev (cons 40 3) #f) w))
  w*)

(define (doc-string w)
  (define ed (content-ed (world-content w)))
  (define v (content-vid-of (world-content w) 0))
  (document-string ed (view-did ed v)))
(define (cursor-col w)
  (define ed (content-ed (world-content w)))
  (define v (content-vid-of (world-content w) 0))
  (view-col ed v))

;;; ---------- 装配：插件把命令 / 键表 / decor 折进 Environment ----------

(check-not-false (command-lookup (environment-commands env) 'auto-pair-insert))
(check-equal? (length (environment-decor env)) 3)      ; syntax + words + bracket

;;; ---------- 自动配对：左括号成对、光标居中 ----------

(define w1 (send (world-with "") (text-event "(")))
(check-equal? (doc-string w1) "()")
(check-equal? (cursor-col w1) 1)                        ; 光标在 ( 与 ) 之间

;;; ---------- 自动配对：右括号跳过已存在的同字符 ----------

(define w2 (send w1 (text-event ")")))
(check-equal? (doc-string w2) "()")                     ; 没有重复插入
(check-equal? (cursor-col w2) 2)                        ; 光标越过 )

;;; ---------- 自动配对：普通文本原样插入（不吞键） ----------

(define w3 (send w2 (text-event "x")))
(check-equal? (doc-string w3) "()x")
(check-equal? (cursor-col w3) 3)

;;; ---------- 自动配对：多字符（粘贴）也走原样插入 ----------

(define w4 (send (world-with "") (text-event "hi")))
(check-equal? (doc-string w4) "hi")

;;; ---------- 括号装饰：深度底色 + 光标配对 ----------

(define wb (world-with "(a (b) c)"))
(define edb (content-ed (world-content wb)))
(define didb (let-values ([(ed v) (values edb (content-vid-of (world-content wb) 0))])
               (view-did ed v)))
(define-values (_fc projs) (ensure-faces (hash) (list bracket-decor) wb))
(check-true (pair? projs))
(commit-faces! edb projs)
(check-not-false (document-face-at edb didb 0 0))       ; 外层括号有深度底色
(check-not-false (document-face-at edb didb 0 3))       ; 内层括号有深度底色

;; 光标在外层 ( 上 → 与配对 ) 都叠 'bracket-match（face-stack）
(define wm (world-with "(a (b) c)"))
(define edm (content-ed (world-content wm)))
(define vm (content-vid-of (world-content wm) 0))
(set-point! edm vm 0 0)
(define-values (_fc2 projs2) (ensure-faces (hash) (list bracket-decor) wm))
(commit-faces! edm projs2)
(check-true (face-stack? (document-face-at edm didb 0 0)))  ; 深度 + 配对叠层
(check-true (face-stack? (document-face-at edm didb 0 8)))  ; 配对括号也被标

;;; ---------- 括号装饰：非 Racket 文件不生效 ----------

(check-equal? (bracket-decor (string->path "t.txt") "(a)" (cons 0 0)) '())

(displayln "edit4/plugins.rkt: all tests passed")
