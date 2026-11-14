#lang racket

;;; 双语异步投影：changes -> timer debounce -> job -> result -> derived mirror。

(require rackunit
         racket/string
         racket/async-channel
         "../editor/host-api.rkt"
         "../edit.rkt"
         "../host/bilingual.rkt"
         "../host/jobs.rkt"
         "../host/timers.rkt"
         "../plugins/bilingual/api.rkt"
         "../plugins/bilingual/model.rkt"
         "../plugins/bilingual/plugin.rkt"
         "../app/layout.rkt")

(define (bytes s) (string->bytes/utf-8 s))

(define text
  (string-append "#lang racket\n"
                 "\n"
                 "(define (main xs)\n"
                 "  (map add1 xs))\n"))

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test.rkt" text))
(void (engine-create-view! engine 1 1))

(define plugins (list bilingual-plugin))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry (plugins->hooks plugins))
                        #:plugins plugins))
(define r (make-resource 1 1 #f "test.rkt" (list 1) 'racket
                         (engine-doc-version engine 1)))
(define layout (make-editor-layout #:editor-view 1))
(define state1
  (make-app-state #:plugin-states (plugins->states plugins)
                  #:resources (resources-add empty-resources r)
                  #:layout layout
                  #:layout-config default-layout-config
                  #:area (rect 0 0 80 24)
                  #:async? #t))

(define ch (make-async-channel))
(define timer-rt (start-timer-runtime #:event-channel ch))
(editor-set-timer-service! ed (timer-runtime-service timer-rt))
(define job-rt (start-job-runtime (editor-services ed)
                                  #:event-channel ch
                                  #:workers 1))

;; 打开 pair；首次投影由 sync 直接提交 job。
(define-values (state2 _actions2)
  (bilingual-open-pair! ed state1 1 #f))
(define state3 (run-plugin-syncs ed state2))
(check-equal? (length (state-pending-jobs state3)) 1)
(check-eq? (job-kind (car (state-pending-jobs state3))) 'bilingual-translate)
(dispatch-jobs! job-rt (state-jobs state3))
(define ev1 (async-channel-get ch))
(check-true (job-result-event? ev1))
(define state4 (handle-job-result ed state3 ev1))
(define mirror-did
  (pair-mirror-doc-id (bilingual-pair-for-source
                       (state-plugin-state state4 'bilingual) 1)))
(check-true (string-contains? (editor-doc-text ed mirror-did) "定义"))
(check-equal? (engine-view-face-at (editor-engine ed) mirror-did 2 1)
              'bilingual-keyword)

;; 源编辑：changes hook 只调度 timer，不立刻翻译。
(define-values (state5 _actions5)
  (editor-replace-lines! ed state4 1 3 4 (list "(define (add a b)")))
(check-equal? (length (state-pending-jobs state5)) 0)
(check-true (string-contains? (editor-doc-text ed mirror-did) "(main xs)"))

;; timer 到期 -> 提交 job。
(define tev (async-channel-get ch))
(check-true (timer-event? tev))
(define-values (state6 _timer-actions)
  (run-plugin-timer-handlers ed state5 tev))
(check-equal? (length (state-pending-jobs state6)) 1)
(check-eq? (job-kind (car (state-pending-jobs state6))) 'bilingual-translate-edit)
(dispatch-jobs! job-rt (state-jobs state6))
(define ev2 (async-channel-get ch))
(check-true (job-result-event? ev2))
(define state7 (handle-job-result ed state6 ev2))
(check-true (string-contains? (editor-doc-text ed mirror-did)
                              "(定义 (add a b)"))

(stop-job-runtime job-rt)
(stop-timer-runtime timer-rt)

(displayln "edit-tui/test/bilingual-async.rkt: ok")
