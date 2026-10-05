#lang racket

(require "machine.rkt"
         "registry.rkt")

;;; lab/plugin/worker.rkt —— 后台 place 进程入口
;;;
;;; 维护影子 + 插件状态（machine.rkt），消息：
;;;   (open   did token path text)    建立 / 重置
;;;   (change did from to path edits) 增量
;;;   (drop   did token)              淘汰
;;;   (close  did)                    丢弃
;;;   (job    tag name did token path) → (tag name fills)

(provide worker-main)

(define (worker-main ch)
  (define mach (make-machine))
  (let loop ()
    (define msg (place-channel-get ch))
    (cond
      [(eq? msg 'stop) (void)]
      [else
       (case (car msg)
         [(open)   (match-define (list _ did token path text) msg)
                   (machine-open! mach did token path text)]
         [(change) (match-define (list _ did from to path edits) msg)
                   (machine-change! mach did from to path edits)]
         [(drop)   (match-define (list _ did token) msg)
                   (machine-drop! mach did token)]
         [(close)  (match-define (list _ did) msg)
                   (machine-close! mach did)]
         [(job)    (match-define (list _ tag name did token path) msg)
                   (define fl (machine-job mach did token name path))
                   (place-channel-put ch (list tag name (or fl '())))]
         [else (void)])
       (loop)])))
