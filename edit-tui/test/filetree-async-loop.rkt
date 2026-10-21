#lang racket

;;; 回归：sync 里刚提交的 filetree job 必须在阻塞读事件前派发，
;;; 否则要等下一个键盘事件才开始扫描 / 绘制。

(require rackunit
         racket/async-channel
         racket/file
         racket/path
         "../config/keymap/default.rkt"
         "../main.rkt")

(define root (make-temporary-file "edit-tui-async-loop-~a" 'directory))
(display-to-file "a" (build-path root "a.txt") #:exists 'truncate)
(display-to-file "b" (build-path root "b.txt") #:exists 'truncate)

(define engine (make-engine))
(void (engine-create-buffer! engine 10 "*filetree*" ""))
(void (engine-create-view! engine 10 10))

(define panel (make-panel 'filetree 'filetree #:views '(10) #:active 10))
(define layout (make-layout #:root (make-leaf 'filetree)
                            #:panels (hash 'filetree panel)
                            #:focus 'filetree))
(define state0
  (struct-copy app-state
               (filetree-install-state
                (make-app-state #:area (rect 0 0 40 10)
                                #:keymap default-keymap)
                10 root
                #:panel-stack filetree-panel-stack)
               [layout layout]))

(define event-channel (make-async-channel))
(define rt (start-job-runtime filetree-services
                              #:event-channel event-channel
                              #:workers 1))
(define calls (box 0))
(define (read-event)
  (set-box! calls (add1 (unbox calls)))
  (cond
    [(= 1 (unbox calls))
     (or (sync/timeout 2 event-channel) (quit-event))]
    [else (quit-event)]))

(define final
  (run-loop state0 engine
            #:read-event read-event
            #:write-bytes void
            #:job-runtime rt))
(stop-job-runtime rt)

(define f (hash-ref (app-state-store final) 'filetree))
(check-true (> (length (filetree-rows f)) 1))
(check-equal? (unbox calls) 2)

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/filetree-async-loop.rkt: ok")
