#lang racket

;;; lab-rebuild/lang/doc-worker.rkt —— 后台查文档的 place 入口
;;;
;;; 消息： (doc id name mods) → (id name signature)（查不到 → (id #f #f)）
;;; xref / bluebox 缓存在 worker 进程内；主进程只收回结果。
;;;
;;; 只认识「名字 + 模块表」，不认识 app / editor（与 lang/ 的定位一致）。

(require racket/match
         "docs.rkt")

(provide worker-main)

(define (worker-main ch)
  (let loop ()
    (define msg (place-channel-get ch))
    (cond
      [(eq? msg 'stop) (void)]
      [else
       (match-define (list 'doc id name mods) msg)
       (define d (with-handlers ([exn:fail? (lambda (_) #f)])
                   (docs-for name #:modules mods)))
       (place-channel-put ch
                          (if d
                              (list id (doc-name d) (doc-signature d))
                              (list id #f #f)))
       (loop)])))
