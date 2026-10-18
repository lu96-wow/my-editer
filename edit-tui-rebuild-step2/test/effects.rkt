#lang racket

;;; edit-tui/test/effects.rkt —— 块 4：engine + effect 解释器
;;;
;;; 运行：racket edit-tui/test/effects.rkt

(require rackunit
         racket/file
         "../../core/editor/ops.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt")

;;; ════════════════ 引擎基础 ════════════════

(define eng (make-engine))
(define did (doc-id 1))
(define vid (view-id 1))

(void (engine-create-doc! eng did "main.rkt" "abc\n"))
(void (engine-create-view! eng vid did))

(check-true (engine-doc-exists? eng did))
(check-true (engine-view-exists? eng vid))
(define ev (make-engine-view eng))
(check-equal? (engine-view-doc-text ev did) "abc\n")
(check-equal? (engine-view-doc-text ev did) "abc\n")
(check-equal? (engine-view-doc-name ev did) "main.rkt")
(check-equal? (engine-view-view-point-line ev vid) 0)
(check-equal? (engine-view-view-point-column ev vid) 0)
(check-equal? (engine-view-view-line-numbers? ev vid) #f)
(check-true (engine-version=? (engine-view-doc-version ev did)
                              (engine-view-doc-version (make-engine-view eng) did)))
(check-equal? (call-with-values (λ () (engine-view-view-cursor-position ev vid)) list)
              '(0 0))

;; 不存在的 id -> #f / (values #f #f)，不抛异常
(check-false (engine-view-doc-text ev (doc-id 99)))
(check-false (engine-view-view-point ev (view-id 99)))
(check-equal? (call-with-values (λ () (engine-view-view-cursor-position ev (view-id 99))) list)
              '(#f #f))

;;; ════════════════ 引擎 effect ════════════════

;; insert
(void (engine-apply! eng (insert-text-effect vid "XY")))
(check-equal? (engine-view-doc-text ev did) "XYabc\n")
(check-equal? (engine-view-view-point-column ev vid) 2)

;; nav
(void (engine-apply! eng (nav-effect vid 'left)))
(check-equal? (engine-view-view-point-column ev vid) 1)
(void (engine-apply! eng (nav-effect vid 'home)))
(check-equal? (engine-view-view-point-column ev vid) 0)
(void (engine-apply! eng (nav-effect vid 'end)))
(check-equal? (engine-view-view-point-column ev vid) 5)

;; select
(void (engine-apply! eng (select-effect vid (selections-one (caret (point 0 1))))))
(check-equal? (engine-view-view-point-column ev vid) 1)

;; edit op（backspace）
(void (engine-apply! eng (edit-effect vid (op-backspace))))
(check-equal? (engine-view-doc-text ev did) "Yabc\n")

;; undo / redo
(void (engine-apply! eng (undo-effect vid)))
(check-equal? (engine-view-doc-text ev did) "XYabc\n")
(void (engine-apply! eng (redo-effect vid)))
(check-equal? (engine-view-doc-text ev did) "Yabc\n")

;; scroll（不报错即可）
(void (engine-apply! eng (scroll-effect vid 3)))

;;; ════════════════ 解释器：open / close ════════════════

(define eng2 (make-engine))
(define s0 (state-empty))
(define spec (make-open-doc-spec "main.rkt" "hello\n"
                                 #:mode 'text
                                 #:path "/tmp/main.rkt"
                                 #:line-numbers? #t))
(define rid (region-id 1))

(define (mount s did vid)
  (define ws (state-workspace s))
  (define ws* (workspace-add-region ws rid
                                    (region rid
                                            (list (view-member vid))
                                            vid
                                            'editor)))
  (define ws** (struct-copy workspace ws* [layout (make-leaf rid)]))
  (transition-pure (state-set-focus (state-set-workspace s ws**) vid)))

(define t-open (interpret-effect! eng2 s0 (open-doc-effect* spec mount)))
(define s1 (transition-state t-open))

(check-equal? (hash-count (engine-docs eng2)) 1)
(check-equal? (hash-count (engine-views eng2)) 1)
(check-equal? (doc-meta-mode (workspace-doc (state-workspace s1) (doc-id 1))) 'text)
(check-equal? (doc-meta-path (workspace-doc (state-workspace s1) (doc-id 1))) "/tmp/main.rkt")
(check-equal? (state-focus s1) (view-id 1))
(check-equal? (workspace-region-views (state-workspace s1) rid) (list (view-id 1)))
(check-true (engine-view-view-line-numbers? (make-engine-view eng2) (view-id 1)))

;; close：engine + state views/region 成员都清掉
(define t-close (interpret-effect! eng2 s1 (close-doc-effect (doc-id 1))))
(define s2 (transition-state t-close))
(check-false (engine-doc-exists? eng2 (doc-id 1)))
(check-false (engine-view-exists? eng2 (view-id 1)))
(check-false (workspace-doc (state-workspace s2) (doc-id 1)))
(check-false (workspace-view (state-workspace s2) (view-id 1)))
(check-equal? (workspace-region-views (state-workspace s2) rid) '())
(check-false (workspace-region-active (state-workspace s2) rid))

;;; ════════════════ save / read / write ════════════════

(define tmp (make-temporary-file "edit-rebuild-~a.txt"))

(define eng3 (make-engine))
(define s3 (state-empty))
(define spec3 (make-open-doc-spec "tmp" "save me" #:path (path->string tmp)))
(define s4
  (transition-state
   (interpret-effect! eng3 s3 (open-doc-effect* spec3 #f))))
(check-equal? (doc-meta-path (workspace-doc (state-workspace s4) (doc-id 1)))
              (path->string tmp))

;; 修改后 save
(void (engine-apply! eng3 (insert-text-effect (view-id 1) "!")))
(define saved? #f)
(define s5
  (transition-state
   (interpret-effect! eng3 s4
                      (save-doc-effect (doc-id 1)
                                       (λ (st ok) (set! saved? ok)
                                          (transition-pure st))))))
(check-true saved?)
(check-equal? (file->string tmp) "!save me")
(define ev3 (make-engine-view eng3))
(define saved-token (doc-meta-saved-version (workspace-doc (state-workspace s5) (doc-id 1))))
(check-true (engine-version=? saved-token (engine-view-doc-version ev3 (doc-id 1))))

;; 版本 token：编辑 -> 变；undo 回保存点 -> 恢复同一 token；文本内容相同也按身份算
(void (engine-apply! eng3 (insert-text-effect (view-id 1) "Z")))
(check-false (engine-version=? saved-token (engine-view-doc-version ev3 (doc-id 1))))
(void (engine-apply! eng3 (undo-effect (view-id 1))))
(check-true (engine-version=? saved-token (engine-view-doc-version ev3 (doc-id 1))))

;; read-file
(define read-val #f)
(void (interpret-effect! eng3 s5
                   (read-file-effect (path->string tmp)
                                     (λ (st text) (set! read-val text)
                                        (transition-pure st)))))
(check-equal? read-val "!save me")

;; write-file
(define write-ok? #f)
(void (interpret-effect! eng3 s5
                   (write-file-effect (path->string tmp) "new"
                                      (λ (st ok) (set! write-ok? ok)
                                         (transition-pure st)))))
(check-true write-ok?)
(check-equal? (file->string tmp) "new")
(delete-file tmp)

;;; ════════════════ quit / runtime effect ════════════════

(check-true (runtime-quit?
             (state-runtime
              (transition-state (interpret-effect! eng3 s5 (quit-effect))))))

(check-exn exn:fail?
           (λ () (interpret-effect! eng3 s5
                                    (spawn-effect (job-id 1) (λ () 1)))))
(check-true (runtime-effect? (spawn-effect (job-id 1) (λ () 1))))
(check-false (runtime-effect? (insert-text-effect (view-id 1) "x")))

;;; ════════════════ 批量顺序 ════════════════

(define eng4 (make-engine))
(define t-batch
  (interpret-effects! eng4 s0
                      (list (open-doc-effect* (make-open-doc-spec "x" "a") #f)
                            (insert-text-effect (view-id 1) "b"))))
(check-equal? (engine-view-doc-text (make-engine-view eng4) (doc-id 1)) "ba")
(check-equal? (hash-count (engine-views eng4)) 1)
(check-false (runtime-quit? (state-runtime (transition-state t-batch))))

(displayln "edit-tui effects: ok")

;;; ════════════════ data continuation ════════════════

(define eng5 (make-engine))
(define s6 (state-empty))
(define spec5 (make-open-doc-spec "cont" "x"))
(define cont (make-continuation 'test-open 'payload))
(define t-cont
  (interpret-effect! eng5 s6
                     (open-doc-effect* spec5 cont)
                     #:continuations
                     (hash 'test-open
                           (λ (st data did vid)
                             (transition-pure
                              (plugin-state-set st 'cont (list data did vid)))))))
(check-equal? (plugin-state (transition-state t-cont) 'cont)
              (list 'payload (doc-id 1) (view-id 1)))

(displayln "edit-tui effects: ok")
