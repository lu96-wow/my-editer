#lang racket

;;; buffer-mode：创建时绑定语言环境 / key table / feature 集。

(require rackunit
         "../main.rkt"
         "../config/mode.rkt")

;; 路径优先：.rkt 即使没有 #lang 也是 Racket mode。
(define m-rkt (buffer-mode-for-creation "a.rkt" ""))
(check-eq? (buffer-mode-id m-rkt) 'racket)
(check-eq? (buffer-mode-language m-rkt) 'racket)
(check-eq? (buffer-mode-key-table m-rkt) racket-buffer-key-table)
(check-true (buffer-mode-supports? m-rkt 'syntax))
(check-true (buffer-mode-supports? m-rkt 'completion))
(check-true (buffer-mode-supports? m-rkt 'docs))

;; 有 path 的 .txt 即使内容像 Racket，也按路径优先走 text mode。
(define m-txt (buffer-mode-for-creation "a.txt" "#lang racket\n(define x 1)"))
(check-eq? (buffer-mode-id m-txt) 'text)
(check-false (buffer-mode-language m-txt))
(check-false (buffer-mode-supports? m-txt 'syntax))

;; 无 path 的 scratch buffer 用 #lang 识别。
(define m-scratch (buffer-mode-for-creation #f "#lang racket\n(define x 1)"))
(check-eq? (buffer-mode-id m-scratch) 'racket)
(define m-plain (buffer-mode-for-creation #f "hello"))
(check-eq? (buffer-mode-id m-plain) 'text)

;; 创建时绑定到 resource；之后读取同一个 mode。
(define-values (store actions)
  (resource-open resource-store-empty
                 #:name "a.rkt"
                 #:path "/tmp/edit-tui-mode-test.rkt"
                 #:text "(define x 1)\n"
                 #:key-table (buffer-mode-key-table m-rkt)
                 #:mode m-rkt))
(define r (resource-ref store 1))
(check-eq? (resource-mode r) m-rkt)

;; rebind：save-as / 改 mode 时 mode 与 key table 一起更新。
(define store* (resource-rebind-mode store 1 m-txt
                                     #:key-table (buffer-mode-key-table m-txt)))
(check-eq? (resource-mode (resource-ref store* 1)) m-txt)
(check-true (command-table-stack? (resource-command-stack store* 1)))

(displayln "edit-tui-rebuild/test/mode.rkt: ok")
