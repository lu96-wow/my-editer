#lang racket

(require "shadow.rkt"
         "api.rkt"
         "registry.rkt")

;;; lab/plugin/worker.rkt —— 后台 place 进程入口
;;;
;;; 每个 did 维护一张 **版本表**（hash token -> 影子文本）：
;;;   (open   did token text)          建立某版本影子
;;;   (change did from to edits)       由 from 增量得 to
;;;   (drop   did token)               淘汰某版本
;;;   (close  did)                     丢弃该文档所有版本
;;;   (job    tag name did token path) 用该版本影子算 → (tag name fills)
;;;
;;; undo/redo 回到旧 token 时影子还在 → 不重算也不重发。

(provide worker-main)

(define (shadow-table shadows did)
  (or (hash-ref shadows did #f)
      (let ([h (make-hash)]) (hash-set! shadows did h) h)))

(define (worker-main ch)
  (define shadows (make-hash))
  (let loop ()
    (define msg (place-channel-get ch))
    (cond
      [(eq? msg 'stop) (void)]
      [else
       (case (car msg)
         [(open)   (match-define (list _ did token text) msg)
                   (hash-set! (shadow-table shadows did) token (shadow-open text))]
         [(change) (match-define (list _ did from to edits) msg)
                   (define t (shadow-table shadows did))
                   (hash-set! t to (shadow-apply (hash-ref t from) edits))]
         [(drop)   (match-define (list _ did token) msg)
                   (hash-remove! (shadow-table shadows did) token)]
         [(close)  (match-define (list _ did) msg)
                   (hash-remove! shadows did)]
         [(job)    (match-define (list _ tag name did token path) msg)
                   (define p (registry-ref name))
                   (define text (shadow-text (hash-ref (shadow-table shadows did) token)))
                   (define fills (if p ((plugin-compute p) (job text path)) '()))
                   (place-channel-put ch (list tag name fills))]
         [else (void)])
       (loop)])))
