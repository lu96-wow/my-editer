#lang racket

;;; edit-rebuild/core/test/session-structure-test.rkt —— 视图 / 布局结构手术（headless）
;;;
;;;   raco test edit-rebuild/core/test/session-structure-test.rkt

(require rackunit
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../session/structure.rkt")

(define s (session-blank 80 24))
(define-values (s1 did vid) (session-add-document s "abc" 40 10 #:name "*t*"))

;; 显示视图：填进编辑区空位并聚焦
(define s2 (session-show-view s1 vid))
(check-equal? (session-focus-vid s2) vid)
(check-equal? (session-edit-vid s2) vid)

;; 分屏：编辑区出现两个视图，焦点移到新视图（粘性）
(define s3 (session-split-focused s2 'lr))
(check-equal? (length (session-view-id-list s3)) 2)
(check-not-eq? (session-focus-vid s3) vid)
(define nvid (session-focus-vid s3))
(check-not-false (memv nvid (session-view-id-list s3)))

;; 关新视图：只剩原视图
(define s4 (session-close-view s3 nvid))
(check-equal? (session-view-id-list s4) (list vid))

;; 隐藏视图：从编辑区移除但不关 view / document
(define s4h (session-hide-view s4 vid))
(check-not-false (memv vid (session-view-id-list s4h)))       ; view 还在
(check-not-false (memv did (session-document-ids s4h)))       ; document 还在

;; 关文档：视图与文档一起消失
(define s5 (session-close-document s4 did))
(check-equal? (session-document-ids s5) '())
(check-equal? (session-view-id-list s5) '())

;; 关文档要连台账一起清（did <-> path / 保存句柄），否则树会显示成“仍打开”
;; 且重开时因命中过时 did 而卡住。
(define-values (sA didA vidA) (session-add-document s "x" 40 10 #:name "*file*"))
(define tmp (build-path (find-system-path 'temp-dir) "edit-structure-test.rkt"))
(define sB (session-set-file sA didA tmp))
(check-equal? (session-file-did sB tmp) didA)
(define sC (session-close-document sB didA))
(check-false (session-file-did sC tmp))
(check-equal? (session-file-dids sC) '())
(check-equal? (session-document-ids sC) '())
