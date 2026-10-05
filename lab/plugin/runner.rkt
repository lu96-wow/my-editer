#lang racket

(require "registry.rkt"
         "shadow.rkt"
         "api.rkt")

;;; lab/plugin/runner.rkt —— 任务执行器接口 + 同步实现
;;;
;;; 影子按 **(did, token)** 存：token 是主进程给每个 document 版本分配的编号。
;;; 于是 undo/redo 回到旧版本时 token 已在缓存里 —— 不用重发文本、不用重算。
;;;
;;;   open!   did token text           建立某版本的影子
;;;   change! did from to edits        由 from 版本增量得到 to 版本
;;;   drop!   did token                淘汰某版本
;;;   close!  did                      丢弃该文档所有版本
;;;   submit! tag name did token path  用该版本影子算 → (tag name fills)
;;;   poll!   (listof (list tag name fills))
;;;   source  evt? / #f                TUI on-source 注册
;;;   stop!   void

(provide make-runner
         runner-open! runner-change! runner-drop! runner-close! runner-submit!
         runner-poll! runner-source runner-stop!
         make-sync-runner)

(struct runner (open-proc change-proc drop-proc close-proc submit-proc
                poll-proc source-proc stop-proc)
  #:transparent)

(define (make-runner open change drop close submit poll source stop)
  (runner open change drop close submit poll source stop))

(define (runner-open! r did token text) ((runner-open-proc r) did token text))
(define (runner-change! r did from to edits) ((runner-change-proc r) did from to edits))
(define (runner-drop! r did token) ((runner-drop-proc r) did token))
(define (runner-close! r did) ((runner-close-proc r) did))
(define (runner-submit! r tag name did token path) ((runner-submit-proc r) tag name did token path))
(define (runner-poll! r) ((runner-poll-proc r)))
(define (runner-source r) ((runner-source-proc r)))
(define (runner-stop! r) ((runner-stop-proc r)))

;; 取 / 建 did 的版本表：hash token -> shadow。
(define (shadow-table shadows did)
  (or (hash-ref shadows did #f)
      (let ([h (make-hash)]) (hash-set! shadows did h) h)))

;;; ---------- 同步 runner（测试 / 无进程环境） ----------

(define (make-sync-runner)
  (define shadows (make-hash))
  (define q (box '()))
  (make-runner
   (lambda (did token text) (hash-set! (shadow-table shadows did) token (shadow-open text)))
   (lambda (did from to edits)
     (define t (shadow-table shadows did))
     (hash-set! t to (shadow-apply (hash-ref t from) edits)))
   (lambda (did token) (hash-remove! (shadow-table shadows did) token))
   (lambda (did) (hash-remove! shadows did))
   (lambda (tag name did token path)
     (define p (registry-ref name))
     (when p
       (define text (shadow-text (hash-ref (shadow-table shadows did) token)))
       (set-box! q (cons (list tag name ((plugin-compute p) (job text path))) (unbox q)))))
   (lambda () (begin0 (reverse (unbox q)) (set-box! q '())))
   (lambda () #f)
   (lambda () (void))))
