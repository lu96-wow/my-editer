#lang racket

;;; require 进来的名字查文档：
;;;   · 库：plain require / prefix-in / rename-in / only-in 都要用**原名**查 xref；
;;;   · 本地文件：prefix-in 后的名字也要用原名去 workspace 里找定义。

(require rackunit
         racket/file
         racket/string
         "../editor/plugin.rkt"
         "../core/job/api.rkt"
         "../lang/racket/api.rkt"
         "../plugins/docs/plugin.rkt")

(define docs-service
  (let ([p (make-docs-plugin #:view 99)])
    (service-handler (car (plugin-services p)))))

;; payload 与 plugins/docs/plugin.rkt 的 docs-service 一致。
(define (docs-lines text name [path "/tmp/docs-required.rkt"] [ws #f] [id #f])
  (docs-service (list name path text (hash) ws id 'racket)))

(define (has-section? lines title)
  (and (member title lines) #t))

;;; ════════════════ 库文档：包装 spec 后仍按原名解析 ════════════════

(define plain
  (docs-lines "#lang racket\n(require racket/list)\n" "first"))
(check-true (has-section? plain "── 文档 ──"))

(define prefixed
  (docs-lines "#lang racket\n(require (prefix-in l: racket/list))\n" "l:first"))
(check-equal? (car prefixed) "l:first")
(check-true (has-section? prefixed "── 文档 ──"))

(define renamed
  (docs-lines "#lang racket\n(require (rename-in racket/list [first fst]))\n" "fst"))
(check-equal? (car renamed) "fst")
(check-true (has-section? renamed "── 文档 ──"))

(define only
  (docs-lines "#lang racket\n(require (only-in racket/list first))\n" "first"))
(check-true (has-section? only "── 文档 ──"))

;;; ════════════════ 查不到库文档：给出诊断信息 ════════════════

(define missing
  (docs-lines "#lang racket\n(require racket/list)\n" "definitely-no-such-name-xyz"))
(check-true (has-section? missing "── 文档 ──"))
(check-true (and (member "没有找到这个标识符的库文档。" missing) #t))

;;; ════════════════ 本地文件：prefix-in 名字 → 原名 → 定义 ════════════════

(define dir (make-temporary-directory))
(define lib (path->string (build-path dir "lib.rkt")))
(define main (path->string (build-path dir "main.rkt")))
(define lib-text "#lang racket\n(provide foo)\n(define (foo x) x)\n")
(define main-text "#lang racket\n(require (prefix-in l: \"lib.rkt\"))\n(define y l:foo)\n")
(define ws
  (workspace-set-doc
   (workspace-set-doc workspace-empty 'lib lib lib-text)
   'main main main-text))

(define local (docs-lines main-text "l:foo" main ws 'main))
(check-true (has-section? local "── 本地定义 ──"))
(check-true (and (member "(define (foo x) x)" local) #t))

(delete-directory/files dir)

(displayln "edit-tui/test/docs-required.rkt: ok")
