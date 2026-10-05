#lang racket

(require "machine.rkt")

;;; lab/plugin/runner.rkt —— 任务执行器接口 + 同步实现
;;;
;;; 影子/插件状态按 (did, token) 缓存（见 machine.rkt）；undo/redo 回到旧 token 不用重算。
;;;
;;;   open!   did token path text      建立某版本（首次 / 重置）
;;;   change! did from to path edits   由 from 增量得 to
;;;   drop!   did token                淘汰某版本
;;;   close!  did                      丢弃该文档
;;;   submit! tag name did token path  取该版本某插件的 fills → (tag name fills)
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

(define (runner-open! r did token path text) ((runner-open-proc r) did token path text))
(define (runner-change! r did from to path edits) ((runner-change-proc r) did from to path edits))
(define (runner-drop! r did token) ((runner-drop-proc r) did token))
(define (runner-close! r did) ((runner-close-proc r) did))
(define (runner-submit! r tag name did token path) ((runner-submit-proc r) tag name did token path))
(define (runner-poll! r) ((runner-poll-proc r)))
(define (runner-source r) ((runner-source-proc r)))
(define (runner-stop! r) ((runner-stop-proc r)))

(define (make-sync-runner)
  (define mach (make-machine))
  (define q (box '()))
  (make-runner
   (lambda (did token path text) (machine-open! mach did token path text))
   (lambda (did from to path edits) (machine-change! mach did from to path edits))
   (lambda (did token) (machine-drop! mach did token))
   (lambda (did) (machine-close! mach did))
   (lambda (tag name did token path)
     (define fl (machine-job mach did token name path))
     (when fl (set-box! q (cons (list tag name fl) (unbox q)))))
   (lambda () (begin0 (reverse (unbox q)) (set-box! q '())))
   (lambda () #f)
   (lambda () (void))))
