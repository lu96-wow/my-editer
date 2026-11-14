#lang racket

;;; 动态词词典的 async 增量路径：
;;;   word job -> 只对包含新词的 source 行提交 retranslate-lines job。

(require rackunit
         racket/async-channel
         racket/string
         "../editor/host-api.rkt"
         "../core/job/api.rkt"
         "../host/jobs.rkt"
         "../host/bilingual.rkt"
         "../app/layout.rkt"
         "../plugins/bilingual/api.rkt"
         "../plugins/bilingual/lexicon.rkt"
         "../plugins/bilingual/plugin.rkt"
         "../edit.rkt")

(define text
  (string-append "#lang racket\n"
                 "\n"
                 "(define (main project-name)\n"
                 "  (+ project-name 1))\n"))

(define word-plugin
  (make-bilingual-plugin
   #:word-translator
   (λ (payload)
     (define words (list-ref payload 2))
     (if (member "project-name" words)
         (list (list "project-name" "项目名" 'bilingual-binding))
         '()))))

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test.rkt" text))
(void (engine-create-view! engine 1 1))
(define ed
  (make-editor #:engine engine
               #:registry (make-hook-registry (plugins->hooks (list word-plugin)))
               #:plugins (list word-plugin)))
(define r (make-resource 1 1 #f "test.rkt" (list 1) 'racket
                         (engine-doc-version engine 1)))
(define layout (make-editor-layout #:editor-view 1))
(define state1
  (make-app-state #:plugin-states (plugins->states (list word-plugin))
                  #:resources (resources-add empty-resources r)
                  #:layout layout
                  #:layout-config default-layout-config
                  #:screen (rect 0 0 80 24)
                  #:async? #t))

(define ch (make-async-channel))
(define rt (start-job-runtime (editor-services ed)
                              #:event-channel ch
                              #:workers 1))

(define (next-job-state! state kind)
  (dispatch-jobs! rt (state-jobs state))
  (define ev (async-channel-get ch))
  (check-true (job-result-event? ev))
  (check-eq? (job-result-event-kind ev) kind)
  (handle-job-result ed state ev))

;; 初始 full 投影。
(define-values (state2 _a2)
  (bilingual-open-pair! ed state1 1 #f))
(define state3 (run-plugin-syncs ed state2))
(define p3 (bilingual-pair-for-source
            (state-plugin-state state3 'bilingual) 1))
(define mirror-did (pair-mirror-doc-id p3))
(define state4 (next-job-state! state3 'bilingual-translate))
(check-true (string-contains? (editor-doc-text ed mirror-did) "project-name"))

;; 发起词翻译。
(define-values (state5 _a5 attached?)
  (editor-focus-view-if-attached! ed state4 1))
(check-true attached?)
(define-values (state6 ps6 _a6)
  (bilingual-request-word-translations! ed state5
                                       (state-plugin-state state5 'bilingual)))
(define state6* (state-set-plugin-state state6 'bilingual ps6))
(define state7 (next-job-state! state6* 'bilingual-word-translate))

;; 词典更新后，async 路径应只提交包含新词的 line patch job。
(define pending7 (state-pending-jobs state7))
(check-equal? (length pending7) 1)
(check-eq? (job-kind (car pending7)) 'bilingual-retranslate-lines)

(define state8 (next-job-state! state7 'bilingual-retranslate-lines))
(check-true (string-contains? (editor-doc-text ed mirror-did) "项目名"))
(check-false (string-contains? (editor-doc-text ed mirror-did)
                              "project-name"))

(stop-job-runtime rt)
(displayln "edit-tui/test/bilingual-lexicon-async.rkt: ok")
