#lang racket

;;; 双语插件：源 user doc <-> derived mirror
;;;   · 源编辑 -> mirror 行刷新
;;;   · mirror 编辑 -> 反译回源 -> mirror 重投影
;;;   · 关闭源 -> mirror 清理

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../app/actions.rkt"
         "../app/event.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "../host/close.rkt"
         "../plugins/bilingual/api.rkt"
         "fixture.rkt")

(define sample
  (string-append "#lang racket\n"
                 "\n"
                 "(define (main xs)\n"
                 "  (map add1 xs))\n"))

(define-values (ed state0)
  (make-editor-app #:initial-text sample
                   #:initial-name "test.rkt"
                   #:initial-resource? #t))

(define source-did 1)
(define source-vid 1)

;; M-l 走插件 command -> action -> host 打开 pair。
(define state1
  (handle-editor-event ed state0 (key-event (key 'l 'alt))))
(define state2 (run-plugin-syncs ed state1))

(define ps (state-plugin-state state2 'bilingual))
(define p (bilingual-pair-for-source ps source-did))
(check-not-false p)
(define mirror-did (pair-mirror-doc-id p))
(define mirror-vid (pair-mirror-view-id p))

;; mirror 是 derived，不是 ui，也不在 user-doc 集合里。
(check-equal? (engine-doc-kind (editor-engine ed) mirror-did) 'derived)
(check-not-false (memv mirror-did (editor-derived-doc-ids ed)))
(check-false (memv mirror-did (editor-user-doc-ids ed)))
(check-true (string-contains? (editor-doc-text ed mirror-did) "定义"))
(check-true (string-contains? (editor-doc-text ed mirror-did) "映射"))
(check-true (string-contains? (editor-doc-text ed mirror-did) "(main xs)"))
(check-equal? (length (editor-visible-editor-panels state2)) 2)

;; 源编辑：替换源第 3 行（0 基），mirror 对应行更新。
(define-values (state3 _actions3)
  (editor-replace-lines! ed state2 source-vid 3 4
                         (list "(define (add a b)")))
(define mirror-text3 (editor-doc-text ed mirror-did))
(check-true (string-contains? mirror-text3 "(定义 (add a b)"))
(check-true (string-contains? mirror-text3 "(main xs)"))

;; mirror 编辑：在 mirror 第 3 行末尾插入注释，反译回源。
(define mirror-line (list-ref (string-split (editor-doc-text ed mirror-did) "\n" #:trim? #f) 3))
(engine-set-view-cursor! (editor-engine ed) mirror-vid 3
                         #:column (string-length mirror-line))
(define state4 state3)
(define-values (state5 actions5)
  (editor-insert! ed state4 mirror-vid " ;mirror"))
(define state6 (run-actions ed state5 actions5))
(define source-text6 (editor-doc-text ed source-did))
(check-true (string-contains? source-text6 "(define (add a b) ;mirror"))
(check-true (string-contains? (editor-doc-text ed mirror-did) ";mirror"))

;; 再跑一帧同步，不应产生新的源变化 / 不应回环。
(define state7 (run-plugin-syncs ed state6))
(check-equal? (editor-doc-text ed source-did) source-text6)

;; 关闭源：mirror doc / pair 都清理。
(define-values (state8 _a8)
  (editor-close-resource! ed state7 source-did))
(check-false (engine-doc-kind (editor-engine ed) mirror-did))
(check-false (bilingual-pair-for-source (state-plugin-state state8 'bilingual)
                                        source-did))
(check-equal? (length (editor-visible-editor-panels state8)) 1)

(displayln "edit-tui/test/bilingual.rkt: ok")
