#lang racket

;;; bilingual 动态词翻译基础：
;;;   · lexicon 冲突 / generation；
;;;   · translator overlay；
;;;   · external word-translate job -> lexicon -> 重新投影 mirror。

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
         "../plugins/bilingual/model.rkt"
         "../plugins/bilingual/plugin.rkt"
         "../plugins/bilingual/translate.rkt"
         "../edit.rkt")

;;; ════════════════ 纯 lexicon ════════════════

(define base default-translator)

(define-values (lex1 added1 conflicts1)
  (lexicon-merge empty-lexicon
                 '(("project-name" "项目名" bilingual-binding))
                 (translator-forward base)
                 (translator-inverse base)))
(check-equal? (length added1) 1)
(check-equal? conflicts1 '())
(check-equal? (lexicon-generation lex1) 1)
(check-true (lexicon-known? lex1 "project-name"))

;; 静态 EN 已有不同翻译：拒绝。
(define-values (lex2 added2 conflicts2)
  (lexicon-merge lex1
                 '(("define" "自定义-定义"))
                 (translator-forward base)
                 (translator-inverse base)))
(check-equal? added2 '())
(check-equal? (length conflicts2) 1)
(check-eq? (caar conflicts2) 'static-en-conflict)

;; CN 已经指向别的 EN：拒绝，避免反译歧义。
(define-values (lex3 added3 conflicts3)
  (lexicon-merge lex1
                 '(("another-name" "定义"))
                 (translator-forward base)
                 (translator-inverse base)))
(check-equal? added3 '())
(check-equal? (length conflicts3) 1)
(check-eq? (caar conflicts3) 'static-cn-conflict)

;; overlay 后动态词可正译 / 反译。
(define tr1
  (translator-with-overrides
   base
   (lexicon-forward lex1)
   (for/hash ([(cn en) (in-hash (lexicon-inverse lex1))])
     (values cn (cons en #f)))
   #:version '(overlay-test)))
(check-equal? ((translator-translate-line tr1) "(project-name x)")
              "(项目名 x)")
(check-equal? ((translator-inverse-line tr1) "(项目名 x)")
              "(project-name x)")

;;; ════════════════ 外部 word job -> 重新投影 ════════════════

(define text
  (string-append "#lang racket\n"
                 "\n"
                 "(define (main project-name)\n"
                 "  project-name)\n"))

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
                  #:area (rect 0 0 80 24)
                  #:async? #f))

(define-values (state2 _actions2)
  (bilingual-open-pair! ed state1 1 #f))
(define state3 (run-plugin-syncs ed state2))
(define p1 (bilingual-pair-for-source
            (state-plugin-state state3 'bilingual) 1))
(define mirror-did (pair-mirror-doc-id p1))
(check-true (string-contains? (editor-doc-text ed mirror-did) "project-name"))

;; 回到 source，发起词翻译请求。
(define-values (state4 _a4 attached?)
  (editor-focus-view-if-attached! ed state3 1))
(check-true attached?)
(define-values (state5 ps5 actions5)
  (bilingual-request-word-translations! ed state4
                                       (state-plugin-state state4 'bilingual)))
(check-equal? actions5 '())
(define lex5 (state-lexicon ps5))
(check-not-false (lexicon-job-id lex5))
(check-true (lexicon-pending? lex5 "project-name"))

;; 直接调用 request（不走 command runtime）时，要按 owner 把 ps 写回 state。
(define state5* (state-set-plugin-state state5 'bilingual ps5))

;; 跑 worker，安装结果。
(define ch (make-async-channel))
(define rt (start-job-runtime (editor-services ed)
                              #:event-channel ch
                              #:workers 1))
(dispatch-jobs! rt (state-jobs state5*))
(define ev (async-channel-get ch))
(stop-job-runtime rt)
(check-true (job-result-event? ev))
(check-eq? (job-result-event-kind ev) 'bilingual-word-translate)

(define state6 (handle-job-result ed state5* ev))
(define ps6 (state-plugin-state state6 'bilingual))
(define lex6 (state-lexicon ps6))
(check-true (lexicon-known? lex6 "project-name"))
(check-false (lexicon-job-id lex6))
(check-equal? (lexicon-generation lex6) 1)

;; 同步模式下一帧用新 translator 重新投影。
(define state7 (run-plugin-syncs ed state6))
(check-true (string-contains? (editor-doc-text ed mirror-did) "项目名"))
(check-false (string-contains? (editor-doc-text ed mirror-did)
                              "(project-name"))

(displayln "edit-tui/test/bilingual-lexicon.rkt: ok")
